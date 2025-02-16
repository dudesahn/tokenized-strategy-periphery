// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

import {BaseHooks, ERC20} from "../Hooks/BaseHooks.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

abstract contract TokenizedStaker is BaseHooks, ReentrancyGuard {
    using SafeERC20 for ERC20;

    struct Reward {
        /// @notice The only address able to top up rewards for a token (aka notifyRewardAmount()).
        address rewardsDistributor;
        /// @notice The duration of our rewards distribution for staking, default is 7 days.
        uint256 rewardsDuration;
        /// @notice The end (timestamp) of our current or most recent reward period.
        uint256 periodFinish;
        /// @notice The distribution rate of reward token per second.
        uint256 rewardRate;
        /**
         * @notice The last time rewards were updated, triggered by updateReward() or notifyRewardAmount().
         * @dev  Will be the timestamp of the update or the end of the period, whichever is earlier.
         */
        uint256 lastUpdateTime;
        /**
         * @notice The most recent stored amount for rewardPerToken().
         * @dev Updated every time anyone calls the updateReward() modifier.
         */
        uint256 rewardPerTokenStored;
        /**
         * @notice The last time a notifyRewardAmount was called.
         * @dev Used for lastRewardRate, a rewardRate equivalent for instant reward releases.
         */
        uint256 lastNotifyTime;
        /// @notice The last rewardRate before a notifyRewardAmount was called
        uint256 lastRewardRate;
    }

    /* ========== EVENTS ========== */

    event RewardAdded(address rewardToken, uint256 reward);
    event RewardPaid(address indexed user, address rewardToken, uint256 reward);
    event RewardsDurationUpdated(address rewardToken, uint256 newDuration);
    event NotifiedWithZeroSupply(address rewardToken, uint256 reward);

    /* ========== MODIFIERS ========== */

    modifier updateReward(address account) {
        _updateReward(account);
        _;
    }

    function _updateReward(address account) internal virtual {
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            address rewardToken = rewardTokens[i];
            rewardData[rewardToken].rewardPerTokenStored = rewardPerToken(
                rewardToken
            );
            rewardData[rewardToken].lastUpdateTime = lastTimeRewardApplicable(
                rewardToken
            );
            if (account != address(0)) {
                rewards[account][rewardToken] = earned(account, rewardToken);
                userRewardPerTokenPaid[account][rewardToken] = rewardData[
                    rewardToken
                ].rewardPerTokenStored;
            }
        }
    }

    /// @notice Array containing the addresses of all of our reward tokens.
    address[] public rewardTokens;

    /// @notice The address of our reward token => reward info.
    mapping(address => Reward) public rewardData;

    /**
     * @notice The amount of rewards allocated to a user per whole token staked.
     * @dev Note that this is not the same as amount of rewards claimed. Mapping order is user -> reward token -> amount
     */
    mapping(address => mapping(address => uint256))
        public userRewardPerTokenPaid;

    /**
     * @notice The amount of unclaimed rewards an account is owed.
     * @dev Mapping order is user -> reward token -> amount
     */
    mapping(address => mapping(address => uint256)) public rewards;

    constructor(address _asset, string memory _name) BaseHooks(_asset, _name) {}

    function _preDepositHook(
        uint256 /* assets */,
        uint256 /* shares */,
        address receiver
    ) internal virtual override {
        _updateReward(receiver);
    }

    function _preWithdrawHook(
        uint256 /* assets */,
        uint256 /* shares */,
        address /* receiver */,
        address owner,
        uint256 /* maxLoss */
    ) internal virtual override {
        _updateReward(owner);
    }

    function _preTransferHook(
        address from,
        address to,
        uint256 /* amount */
    ) internal virtual override {
        _updateReward(from);
        _updateReward(to);
    }

    /// @notice Either the current timestamp or end of the most recent period.
    function lastTimeRewardApplicable(
        address rewardToken
    ) public view virtual returns (uint256) {
        return
            block.timestamp < rewardData[rewardToken].periodFinish
                ? block.timestamp
                : rewardData[rewardToken].periodFinish;
    }

    /// @notice Reward paid out per whole token.
    function rewardPerToken(
        address rewardToken
    ) public view virtual returns (uint256) {
        uint256 _totalSupply = TokenizedStrategy.totalSupply();
        if (_totalSupply == 0 || rewardData[rewardToken].rewardsDuration == 1) {
            return rewardData[rewardToken].rewardPerTokenStored;
        }

        if (TokenizedStrategy.isShutdown()) {
            return 0;
        }

        return
            rewardData[rewardToken].rewardPerTokenStored +
            (((lastTimeRewardApplicable(rewardToken) -
                rewardData[rewardToken].lastUpdateTime) *
                rewardData[rewardToken].rewardRate *
                1e18) / _totalSupply);
    }

    /// @notice Amount of reward token pending claim by an account.
    function earned(
        address account,
        address rewardToken
    ) public view virtual returns (uint256) {
        if (TokenizedStrategy.isShutdown()) {
            return 0;
        }

        return
            (TokenizedStrategy.balanceOf(account) *
                (rewardPerToken(rewardToken) -
                    userRewardPerTokenPaid[account][rewardToken])) /
            1e18 +
            rewards[account][rewardToken];
    }

    /// @notice Reward tokens emitted over the entire rewardsDuration.
    function getRewardForDuration(
        address rewardToken
    ) external view virtual returns (uint256) {
        return
            rewardData[rewardToken].rewardRate *
            rewardData[rewardToken].rewardsDuration;
    }

    /**
     * @notice Notify staking contract that it has more reward to account for.
     * @dev May only be called by rewards distribution role or management. Set up token first via addReward().
     * @param _rewardsToken Address of the rewards token.
     * @param _rewardAmount Amount of reward tokens to add.
     */
    function notifyRewardAmount(
        address _rewardToken,
        uint256 _rewardAmount
    ) external virtual {
        _notifyRewardAmount(_rewardToken, _rewardAmount);
    }

    function _notifyRewardAmount(
        address _rewardToken,
        uint256 _rewardAmount
    ) internal virtual updateReward(address(0)) {
        Reward memory _rewardData = rewardData[_rewardsToken];
        require(_rewardAmount > 0 && _rewardAmount < 1e30, "bad reward value");
        require(
            _rewardData.rewardsDistributor == msg.sender ||
                msg.sender == TokenizedStrategy.management(),
            "!authorized"
        );

        // handle the transfer of reward tokens via `transferFrom` to reduce the number
        // of transactions required and ensure correctness of the reward amount
        ERC20(_rewardsToken).safeTransferFrom(
            msg.sender,
            address(this),
            _rewardAmount
        );

        /// @COMMENT moved this from the instant version, good to prevent against generally tbh (see sommelier report)
        // If total supply is 0, send tokens to management instead of reverting.
        // Prevent footguns if _notifyRewardInstant() is part of predeposit hooks.
        uint256 _totalSupply = TokenizedStrategy.totalSupply();
        if (_totalSupply == 0) {
            address management = TokenizedStrategy.management();

            ERC20(_rewardToken).safeTransfer(management, _rewardAmount);
            emit NotifiedWithZeroSupply(_rewardToken, reward);
            return;
        }

        /// @dev A rewardsDuration of 1 dictates instant release of rewards
        if (_rewardData.rewardsDuration == 1) {
            _notifyRewardInstant(_rewardToken, _rewardAmount, _rewardData);
        } else {
            // store current rewardRate
            _rewardData.lastRewardRate = _rewardData.rewardRate;

            // update time-based struct fields
            _rewardData.lastNotifyTime = block.timestamp;
            _rewardData.lastUpdateTime = block.timestamp;
            _rewardData.periodFinish =
                block.timestamp +
                _rewardData.rewardsDuration;

            // update our rewardData with our new rewardRate
            if (block.timestamp >= _rewardData.periodFinish) {
                _rewardData.rewardRate =
                    _rewardAmount /
                    _rewardData.rewardsDuration;
            } else {
                _rewardData.rewardRate =
                    (_rewardAmount +
                        (_rewardData.periodFinish - block.timestamp) *
                        _rewardData.rewardRate) /
                    _rewardData.rewardsDuration;
            }

            // write to storage
            rewardData[_rewardsToken] = _rewardData;
            emit RewardAdded(_rewardsToken, _rewardAmount);
        }
    }

    function _notifyRewardInstant(
        address _rewardToken,
        uint256 _rewardAmount,
        Reward memory _rewardData
    ) internal virtual {
        // Update lastNotifyTime and lastRewardRate if needed
        if (block.timestamp != _rewardData.lastNotifyTime) {
            _rewardData.lastRewardRate =
                _rewardAmount /
                (block.timestamp - _rewardData.lastNotifyTime); ///@COMMENT I think this should include the non-instant? guess not since you must wait until period ends to update length,
            // so if we're notifying instant we know there isn't any other rewards that will be available that block. *** can you notify twice in the same block?
            _rewardData.lastNotifyTime = block.timestamp;
        }

        // Update rewardRate, lastUpdateTime, periodFinish
        _rewardData.rewardRate = 0; /// @COMMENT not sure if this is correct...shouldn't we still calculate this?
        _rewardData.lastUpdateTime = block.timestamp;
        _rewardData.periodFinish = block.timestamp;

        // Instantly release rewards by modifying rewardPerTokenStored
        rewardData[_rewardToken].rewardPerTokenStored =
            rewardData[_rewardToken].rewardPerTokenStored +
            (reward * 1e18) /
            _totalSupply;

        // write to storage
        rewardData[_rewardsToken] = _rewardData;
        emit RewardAdded(_rewardsToken, _rewardAmount);
    }

    /// @notice Claim any earned reward tokens.
    /// @dev Can claim rewards even if no tokens still staked.
    function getReward() public virtual nonReentrant updateReward(msg.sender) {
        for (uint256 i = 0; i < rewardTokens.length; ++i) {
            address rewardToken = rewardTokens[i];
            uint256 reward = rewards[msg.sender][rewardToken];
            if (reward > 0) {
                rewards[msg.sender][rewardToken] = 0;
                ERC20(rewardToken).safeTransfer(msg.sender, reward);
                emit RewardPaid(msg.sender, rewardToken, reward);
            }
        }
    }

    /**
     * @notice Claim any one earned reward token.
     * @dev Can claim rewards even if no tokens still staked.
     * @param _rewardsToken Address of the rewards token to claim.
     */
    function getOneReward(
        address _rewardsToken
    ) external virtual nonReentrant updateReward(msg.sender) {
        uint256 reward = rewards[msg.sender][_rewardsToken];
        if (reward > 0) {
            rewards[msg.sender][_rewardsToken] = 0;
            ERC20(_rewardsToken).safeTransfer(msg.sender, reward);
            emit RewardPaid(msg.sender, _rewardsToken, reward);
        }
    }

    /// @notice Unstake all of the sender's tokens and claim any outstanding rewards.
    /// @COMMENT should probably allow user to pass in how much loss they want to allow here...or have settable MAX_LOSS?
    function exit() external virtual {
        redeem(
            TokenizedStrategy.balanceOf(msg.sender),
            msg.sender,
            msg.sender,
            10_000
        );
        getReward();
    }

    /**
     * @notice Add a new reward token to the staking contract.
     * @dev May only be called by management, and can't be set to zero address. Add reward tokens sparingly, as each new
     *  one will increase gas costs. This must be set before notifyRewardAmount can be used. A rewardsDuration of 1
     *  dictates instant release of rewards.
     * @param _rewardsToken Address of the rewards token.
     * @param _rewardsDistributor Address of the rewards distributor.
     * @param _rewardsDuration The duration of our rewards distribution for staking in seconds.
     */
    function addReward(
        address _rewardsToken,
        address _rewardsDistributor,
        uint256 _rewardsDuration
    ) external virtual onlyManagement {
        _addReward(_rewardsToken, _rewardsDistributor, _rewardsDuration);
    }

    /// @dev Internal function to add a new reward token to the staking contract.
    function _addReward(
        address _rewardsToken,
        address _rewardsDistributor,
        uint256 _rewardsDuration
    ) internal virtual {
        require(
            _rewardsToken != address(0) && _rewardsDistributor != address(0),
            "No zero address"
        );
        require(_rewardsDuration > 0, "Must be >0");
        require(
            rewardData[_rewardsToken].rewardsDuration == 0,
            "Reward already added"
        );

        rewardTokens.push(_rewardsToken);
        rewardData[_rewardsToken].rewardsDistributor = _rewardsDistributor;
        rewardData[_rewardsToken].rewardsDuration = _rewardsDuration;
    }

    /**
     * @notice Set the duration of our rewards period.
     * @dev May only be called by management, and must be done after most recent period ends.
     * @param _rewardsToken Address of the rewards token.
     * @param _rewardsDuration New length of period in seconds.
     */
    function setRewardsDuration(
        address _rewardToken,
        uint256 _rewardsDuration
    ) external virtual onlyManagement {
        _setRewardsDuration(_rewardToken, _rewardsDuration);
    }

    function _setRewardsDuration(
        address _rewardToken,
        uint256 _rewardsDuration
    ) internal virtual {
        require(
            block.timestamp > rewardData[_rewardToken].periodFinish,
            "Previous rewards period must be complete before changing the duration for the new period"
        );
        require(_rewardsDuration > 0, "Must be >0");
        rewardData[_rewardToken].rewardsDuration = _rewardsDuration;
        emit RewardsDurationUpdated(_rewardToken, _rewardsDuration);
    }
}
