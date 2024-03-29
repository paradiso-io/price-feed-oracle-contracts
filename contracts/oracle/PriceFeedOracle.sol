// SPDX-License-Identifier: MIT
pragma solidity ^0.7.0;

import "../lib/math/Median.sol";
import "../lib/math/SafeMath128.sol";
import "../lib/math/SafeMath32.sol";
import "../lib/math/SafeMath64.sol";
import "../interfaces/IPriceFeed.sol";
import "./OracleFundManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./OraclePaymentManager.sol";
import "./PFConfig.sol";
import "../lib/access/EOACheck.sol";
import "../lib/access/SRAC.sol";
import "@openzeppelin/contracts/proxy/Initializable.sol";

/**
 * @title The Prepaid Oracle contract
 * @notice Handles aggregating data pushed in from off-chain, and unlocks
 * payment for oracles as they report. Oracles' submissions are gathered in
 * rounds, with each round aggregating the submissions for each oracle into a
 * single answer. The latest aggregated answer is exposed as well as historical
 * answers and their updated at timestamp.
 */
contract PriceFeedOracle is
    IPriceFeed,
    OraclePaymentManager,
    SRAC,
    Initializable
{
    using SafeMath for uint256;
    using SafeMath128 for uint128;
    using SafeMath64 for uint64;
    using SafeMath32 for uint32;
    using SafeERC20 for IERC20;
    using EOACheck for address;

    struct Round {
        int256 answer;
        uint64 updatedAt; //timestamp
        uint32 answeredInRound;
        int256[] submissions;
        uint128 paymentAmount;
    }

    struct SubmitterRewardsVesting {
        uint64 lastUpdated;
        uint128 releasable;
        uint128 remainVesting;
    }

    string public override description;

    uint256 public constant override version = 1;
    uint256 public constant MIN_THRESHOLD_PERCENT = 66;
    uint128 public percentX10SubmitterRewards = 5; //0.5%
    uint256 public constant SUBMITTER_REWARD_VESTING_PERIOD = 30 days;
    mapping(address => SubmitterRewardsVesting) public submitterRewards;

    mapping(uint32 => Round) internal rounds;

    event SubmissionReceived(int256 price, uint32 indexed round);

    function initialize(
        address _dto,
        uint128 _paymentAmount,
        address _validator,
        string memory _description
    ) public initializer {
        super.initialize(_dto, _paymentAmount);
        setChecker(_validator);
        description = _description;
        rounds[0].updatedAt = uint64(block.timestamp);
    }

    /*
     * ----------------------------------------ORACLE FUNCTIONS------------------------------------------------
     */

    /**
     * @notice V1, testnet, use simple ECDSA signatures combined in a single transaction
     * @notice called by oracles when they have witnessed a need to update, V1 uses ECDSA, V2 will use threshold shnorr singnature
     * @param _roundId is the ID of the round this submission pertains to
     * @param _prices are the updated data that the oracles are submitting
     * @param _deadline time at which the price is still valid. this time is determined by the oracles
     * @param r are the r signature data that the oracles are submitting
     * @param s are the s signature data that the oracles are submitting
     * @param v are the v signature data that the oracles are submitting
     */
    function submit(
        uint32 _roundId,
        int256[] memory _prices,
        uint256 _deadline,
        bytes32[] memory r,
        bytes32[] memory s,
        uint8[] memory v
    ) external {
        updateAvailableFunds();
        require(
            _deadline >= block.timestamp,
            "PriceFeedOracle::submit deadline over"
        );
        require(
            _prices.length == r.length &&
                r.length == s.length &&
                s.length == v.length,
            "PriceFeedOracle::submit Invalid input paramters length"
        );
        require(
            v.length.mul(100).div(oracleAddresses.length) >=
                MIN_THRESHOLD_PERCENT,
            "PriceFeedOracle::submit Number of submissions under threshold"
        );

        require(
            _roundId == lastReportedRound.add(1),
            "PriceFeedOracle::submit Invalid RoundId"
        );
        createNewRound(_roundId);

        bytes32 message = keccak256(
            abi.encodePacked(
                "\x19Ethereum Signed Message:\n32",
                keccak256(
                    abi.encode(
                        _roundId,
                        address(this),
                        _prices,
                        _deadline,
                        description
                    )
                )
            )
        );
        for (uint256 i = 0; i < _prices.length; i++) {
            address signer = ecrecover(message, v[i], r[i], s[i]);
            //the off-chain network dotoracle must verify there is no duplicate oracles in the submissions
            require(
                isOracleEnabled(signer),
                "PriceFeedOracle::submit submissions data corrupted or invalid"
            );
            payOracle(_roundId, signer);
        }
        accPaymentPerOracle = accPaymentPerOracle.add(paymentAmount.mul(uint128(1000) - percentX10SubmitterRewards).div(1000));
        updateAvailableFunds();
        emit AvailableFundsUpdated(recordedFunds.available);

        (bool updated, int256 newAnswer) = updateRoundPrice(
            uint32(_roundId),
            _prices
        );
        if (updated) {
            validateRoundPrice(uint32(_roundId), newAnswer);
            emit SubmissionReceived(newAnswer, uint32(_roundId));
        }

        //pay submitter rewards for incentivizations
        uint128 submitterRewardsToAppend = uint128(
            _prices
            .length
            .mul(paymentAmount)
            .mul(percentX10SubmitterRewards)
            .div(1000)
        );

        appendSubmitterRewards(msg.sender, submitterRewardsToAppend);
    }

    function appendSubmitterRewards(address _submitter, uint128 _rewardsToAdd)
        internal
    {
        _updateSubmitterWithdrawnableRewards(_submitter);
        submitterRewards[_submitter].remainVesting = submitterRewards[
            _submitter
        ]
        .remainVesting
        .add(_rewardsToAdd);
    }

    function _updateSubmitterWithdrawnableRewards(address _submitter) internal {
        SubmitterRewardsVesting storage vestingInfo = submitterRewards[
            _submitter
        ];
        if (vestingInfo.remainVesting > 0) {
            uint128 unlockable = uint128(
                (block.timestamp.sub(vestingInfo.lastUpdated))
                .mul(vestingInfo.remainVesting)
                .div(SUBMITTER_REWARD_VESTING_PERIOD)
            );
            if (unlockable > vestingInfo.remainVesting) {
                unlockable = vestingInfo.remainVesting;
            }
            vestingInfo.remainVesting = vestingInfo.remainVesting.sub(
                unlockable
            );
            vestingInfo.releasable = vestingInfo.releasable.add(unlockable);
        }
        vestingInfo.lastUpdated = uint64(block.timestamp);
    }

    function unlockSubmitterRewards(address _submitter) external {
        _updateSubmitterWithdrawnableRewards(_submitter);
        if (submitterRewards[_submitter].releasable > 0) {
            dtoToken.safeTransfer(
                _submitter,
                submitterRewards[_submitter].releasable
            );
            recordedFunds.allocated = recordedFunds.allocated.sub(
                submitterRewards[_submitter].releasable
            );
            updateAvailableFunds();
            submitterRewards[_submitter].releasable = 0;
        }
    }

    function addFunds(uint256 _amount) external {
        dtoToken.safeTransferFrom(msg.sender, address(this), _amount);
        updateAvailableFunds();
    }

    /**
     * Private
     */

    function createNewRound(uint32 _roundId) private {
        updateRoundInfo(_roundId);

        lastReportedRound = _roundId;
        rounds[_roundId].updatedAt = uint64(block.timestamp);

        emit NewRound(_roundId, msg.sender, rounds[_roundId].updatedAt);
    }

    function validateRoundPrice(uint32 _roundId, int256 _newAnswer) private {
        IDataChecker av = checker; // cache storage reads
        if (address(av) == address(0)) return;

        uint32 prevRound = _roundId.sub(1);
        uint32 prevAnswerRoundId = rounds[prevRound].answeredInRound;
        int256 prevRoundAnswer = rounds[prevRound].answer;
        // We do not want the validator to ever prevent reporting, so we limit its
        // gas usage and catch any errors that may arise.
        try
            av.validate{gas: VALIDATOR_GAS_LIMIT}(
                prevAnswerRoundId,
                prevRoundAnswer,
                _roundId,
                _newAnswer
            )
        {} catch {}
    }

    function updateRoundInfo(uint32 _roundId) private {
        uint32 prevId = _roundId.sub(1);
        rounds[_roundId].answer = rounds[prevId].answer;
        rounds[_roundId].answeredInRound = rounds[prevId].answeredInRound;
        rounds[_roundId].updatedAt = uint64(block.timestamp);
    }

    function updateRoundPrice(uint32 _roundId, int256[] memory _prices)
        internal
        returns (bool, int256)
    {
        int256 newAnswer = Median.calculateInplace(_prices);
        rounds[_roundId].answer = newAnswer;
        rounds[_roundId].updatedAt = uint64(block.timestamp);
        rounds[_roundId].answeredInRound = _roundId;

        emit AnswerUpdated(newAnswer, _roundId, block.timestamp);

        return (true, newAnswer);
    }

    function payOracle(uint32 _roundId, address _oracle) private {
        uint128 payment = paymentAmount;
        Funds memory funds = recordedFunds;
        funds.available = funds.available.sub(payment);
        funds.allocated = funds.allocated.add(payment);
        recordedFunds = funds;
        OraclePayment(_roundId, _oracle, payment);
    }

    /*
     * ----------------------------------------VIEW FUNCTIONS------------------------------------------------
     */
    function latestAnswer()
        public
        view
        virtual
        override
        checkAccess
        returns (int256)
    {
        return rounds[lastReportedRound].answer;
    }

    function latestUpdated() public view virtual override returns (uint256) {
        return rounds[lastReportedRound].updatedAt;
    }

    function latestRound() public view virtual override returns (uint256) {
        return lastReportedRound;
    }

    function getAnswerByRound(uint256 _roundId)
        public
        view
        virtual
        override
        checkAccess
        returns (int256)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].answer;
        }
        return 0;
    }

    function getUpdatedTime(uint256 _roundId)
        public
        view
        virtual
        override
        returns (uint256)
    {
        if (validRoundId(_roundId)) {
            return rounds[uint32(_roundId)].updatedAt;
        }
        return 0;
    }

    function getRoundInfo(uint80 _roundId)
        public
        view
        virtual
        override
        checkAccess
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        Round memory r = rounds[uint32(_roundId)];

        require(
            r.answeredInRound > 0 && validRoundId(_roundId),
            V3_NO_DATA_ERROR
        );

        return (_roundId, r.answer, r.updatedAt, r.answeredInRound);
    }

    function latestRoundInfo()
        public
        view
        virtual
        override
        checkAccess
        returns (
            uint80 roundId,
            int256 answer,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return getRoundInfo(lastReportedRound);
    }

    /**
     * @notice get the admin address of an oracle
     * @param _oracle is the address of the oracle whose admin is being queried
     */
    function getAdmin(address _oracle) external view returns (address) {
        return oracles[_oracle].admin;
    }

    /**
     * @notice a method to provide all current info oracles need. Intended only
     * only to be callable by oracles. Not for use by contracts to read state.
     * @param _oracle the address to look up information for.
     */
    function oracleRoundState(address _oracle, uint32 _queriedRoundId)
        external
        view
        checkAccess
        returns (
            bool _eligibleToSubmit,
            uint32 _roundId,
            uint128 _availableFunds,
            uint8 _oracleCount,
            uint128 _paymentAmount
        )
    {
        require(
            address(msg.sender).isCalledFromEOA(),
            "off-chain reading only"
        );
        require(_queriedRoundId > 0, "_queriedRoundId > 0");

        Round storage round = rounds[_queriedRoundId];
        return (
            eligibleForSpecificRound(_oracle, _queriedRoundId),
            _queriedRoundId,
            recordedFunds.available,
            oracleCount(),
            (round.updatedAt > 0 ? round.paymentAmount : paymentAmount)
        );
    }

    function eligibleForSpecificRound(address _oracle, uint32 _queriedRoundId)
        private
        view
        returns (bool _eligible)
    {
        return oracles[_oracle].endingRound >= _queriedRoundId;
    }

    function validRoundId(uint256 _roundId) private pure returns (bool) {
        return _roundId <= ROUND_MAX;
    }
}
