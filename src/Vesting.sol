// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Vesting
 * @notice 代币归属（Vesting）合约：部署后立刻开始计算 Cliff，受益人通过 release() 领取已解锁的 ERC20。
 *
 * 解锁规则（一个月按 30 天计）：
 *  - Cliff（悬崖期）：部署起的第 1 ~ 12 个月（360 天），解锁量为 0，任何人都领不到；
 *  - 线性释放期：Cliff 结束后的 24 个月（720 天，即第 13 ~ 36 个月），每月解锁总量的 1/24：
 *    · 第 13 个月：1/24
 *    · 第 14 个月：2/24
 *    · ...
 *    · 第 36 个月：24/24 = 100%
 *
 * @dev 本合约不继承任何合约，状态与逻辑全部自己实现（只使用 OpenZeppelin 的 IERC20 接口和 SafeERC20 库，
 *      库调用不属于继承）：
 *      - 时间轴 start / cliff / end 都是 immutable，部署时按 block.timestamp 一次性算好；
 *      - 已释放数量用本合约自己的账本 _released 记录，release() 与 release(address) 共用同一套账本；
 *      - 解锁曲线由 _vestingSchedule 给出：Cliff 内为 0；之后从 cliff 起算，在 24 个月内线性释放。
 */
contract Vesting {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // 时间与数量参数
    // ---------------------------------------------------------------------

    /// @notice 一个月的秒数（按月 = 30 天计）。
    uint64 public constant MONTH = 30 days;

    /// @notice Cliff（悬崖期）时长：12 个月 = 360 天。
    uint64 public constant CLIFF_DURATION = 12 * MONTH;

    /// @notice 线性释放时长：Cliff 结束后的 24 个月 = 720 天。
    uint64 public constant VESTING_DURATION = 24 * MONTH;

    /// @notice 线性释放期一共多少个月（每月解锁 1/24）。
    uint256 public constant VESTING_MONTHS = 24;

    /// @notice 默认锁定的代币数量：100 万 ERC20（按 18 位小数计）。
    uint256 public constant LOCKED_AMOUNT = 1_000_000e18;

    // ---------------------------------------------------------------------
    // 部署时确定的不可变参数
    // ---------------------------------------------------------------------

    /// @notice 受益人：所有解锁的代币都只会转给它。
    address public immutable beneficiary;

    /// @notice 被锁定的 ERC20 代币地址。
    IERC20 public immutable token;

    /// @notice 归属起始时间：部署时刻，Cliff 从这里开始计算。
    uint64 public immutable start;

    /// @notice Cliff 结束时间（= start + 12 个月）。
    uint64 public immutable cliff;

    /// @notice 归属结束时间（= start + 36 个月，此时 100% 解锁）。
    uint64 public immutable end;

    // ---------------------------------------------------------------------
    // 状态
    // ---------------------------------------------------------------------

    /// @dev 已释放账本：token => 已经转给受益人的数量。
    mapping(address token => uint256 amount) private _released;

    // ---------------------------------------------------------------------
    // 事件与错误
    // ---------------------------------------------------------------------

    /// @notice 释放代币给受益人时触发。
    event ERC20Released(address indexed token, uint256 amount);

    /// @notice 代币被转入本合约时触发。
    event Funded(address indexed funder, uint256 amount);

    /// @notice 受益人地址为零地址。
    error InvalidBeneficiary();

    /// @notice 代币地址为零地址。
    error InvalidTokenAddress();

    /// @notice 转入数量为 0。
    error ZeroAmount();

    /// @notice 合约不接受原生代币（ETH），避免资产被永久锁定。
    error EtherNotAccepted();

    /**
     * @param beneficiary_ 受益人地址，解锁后只能由它收到代币。
     * @param token_ 锁定的 ERC20 代币地址。
     */
    constructor(address beneficiary_, IERC20 token_) {
        if (beneficiary_ == address(0)) revert InvalidBeneficiary();
        if (address(token_) == address(0)) revert InvalidTokenAddress();

        beneficiary = beneficiary_;
        token = token_;

        // 部署后立刻开始计算 Cliff。
        uint64 startTime = uint64(block.timestamp);
        start = startTime;
        cliff = startTime + CLIFF_DURATION;
        end = startTime + CLIFF_DURATION + VESTING_DURATION;
    }

    // ---------------------------------------------------------------------
    // 查询
    // ---------------------------------------------------------------------

    /// @notice 整个归属周期：Cliff 12 个月 + 线性释放 24 个月 = 36 个月。
    function duration() external pure returns (uint256) {
        return CLIFF_DURATION + VESTING_DURATION;
    }

    /**
     * @notice 指定代币在某个时间点累计已解锁（已归属）的数量。
     * @param token_ ERC20 代币地址。
     * @param timestamp 时间点（Unix 时间戳）。
     * @dev 总量 = 合约当前余额 + 已经释放出去的数量（已释放的部分不在余额里，所以要加回来）。
     */
    function vestedAmount(address token_, uint64 timestamp) public view returns (uint256) {
        uint256 totalAllocation = IERC20(token_).balanceOf(address(this)) + _released[token_];
        return _vestingSchedule(totalAllocation, timestamp);
    }

    /**
     * @notice 锁定代币在指定时间点累计已解锁的数量。
     * @param timestamp 时间点（Unix 时间戳）。
     */
    function vestedTokenAmount(uint64 timestamp) public view returns (uint256) {
        return vestedAmount(address(token), timestamp);
    }

    /// @notice 指定代币累计已释放给受益人的数量。
    function released(address token_) public view returns (uint256) {
        return _released[token_];
    }

    /// @notice 指定代币当前还可以释放的数量（= 已解锁 - 已释放）。
    function releasable(address token_) public view returns (uint256) {
        return vestedAmount(token_, uint64(block.timestamp)) - _released[token_];
    }

    /// @notice 锁定代币当前还可以释放的数量。
    function releasableToken() external view returns (uint256) {
        return releasable(address(token));
    }

    // ---------------------------------------------------------------------
    // 释放与注资
    // ---------------------------------------------------------------------

    /**
     * @notice 释放当前已解锁（已归属）的 ERC20 给受益人。
     * @dev 任何人都可以调用，但代币只会转给受益人，调用者无法卷走资产；
     *      没有新解锁的代币时（例如 Cliff 期内）不转账、不报错，是安全的空操作。
     */
    function release() external {
        _release(address(token));
    }

    /**
     * @notice 释放指定代币：与 release() 共用同一套账本与转账逻辑。
     * @param token_ ERC20 代币地址。
     */
    function release(address token_) external {
        _release(token_);
    }

    /**
     * @notice 一次性转入默认锁定的 100 万 ERC20。
     * @dev 调用前需要先 approve 本合约至少 LOCKED_AMOUNT 的代币额度。
     */
    function fund() external {
        _fund(LOCKED_AMOUNT);
    }

    /**
     * @notice 转入指定数量的 ERC20 到本合约（转入的代币按同一套时间表解锁）。
     * @param amount 转入数量。
     */
    function fund(uint256 amount) external {
        _fund(amount);
    }

    // ---------------------------------------------------------------------
    // 内部实现
    // ---------------------------------------------------------------------

    /**
     * @dev 释放逻辑：
     *      1. 本次可释放数量 = 已解锁数量（按解锁曲线算出） - 已经释放过的数量；
     *      2. 先更新账本，再用 SafeERC20 转账给受益人（先改状态、后转账，防重入）。
     */
    function _release(address token_) private {
        uint256 amount = vestedAmount(token_, uint64(block.timestamp)) - _released[token_];
        if (amount == 0) {
            return;
        }

        _released[token_] += amount;
        emit ERC20Released(token_, amount);
        IERC20(token_).safeTransfer(beneficiary, amount);
    }

    /// @dev 注资：从调用者转入代币，并记录事件。
    function _fund(uint256 amount) private {
        if (amount == 0) revert ZeroAmount();

        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Funded(msg.sender, amount);
    }

    /**
     * @dev 解锁曲线：
     *      - timestamp < cliff：Cliff 期内，返回 0；
     *      - timestamp >= end：完全解锁，返回全部；
     *      - 其余（第 13 ~ 36 个月）：从 cliff 起算的线性释放，每月解锁 1/24。
     */
    function _vestingSchedule(uint256 totalAllocation, uint64 timestamp) private view returns (uint256) {
        if (timestamp < cliff) {
            return 0;
        }
        if (timestamp >= end) {
            return totalAllocation;
        }
        return (totalAllocation * (timestamp - cliff)) / (end - cliff);
    }

    /// @dev 本合约只锁定 ERC20，拒绝接收 ETH。
    receive() external payable {
        revert EtherNotAccepted();
    }
}
