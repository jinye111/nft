// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title RebaseToken
 * @notice 通缩型 Rebase ERC20：初始发行 1 亿枚，每满一年总量在上一年的基础上下降 1%（复利通缩）。
 * @dev 继承 OpenZeppelin ERC20，复用标准接口、元数据（name/symbol/decimals）、
 * 授权逻辑（approve/allowance/_spendAllowance）以及标准错误类型（ERC20InsufficientBalance 等）。
 *
 * ── 一、两套账：gons（内部）与 fragment（对外） ──
 * 对外账（fragment）：钱包、DEX、其他合约看到并操作的数量，会随 rebase 变小。
 * 内部账（gons）    ：真正存在链上的数字，只要不转账就恒定不变。
 *   balanceOf(user) = _gonsBalances[user] / _gonsPerFragment
 *   totalSupply()   = _totalFragments                 // 每次 rebase 直接乘 0.99
 * rebase 只做两件事：把 _totalFragments 乘 0.99、把 _gonsPerFragment 调大。
 * 所有地址的 gons 一个都没动，但除数变大了 —— 于是每个人的显示余额按同一比例缩水。
 * 这就是 rebase 型代币的核心：不需要遍历用户数组，只改一个全局汇率，
 * 就能让全体持有人同时"通缩"（或同时"生息"，方向取决于汇率调大还是调小）。
 *
 * ── 二、扩展点：只覆盖 _update() ──
 * OZ 把 _balances / _totalSupply 声明为 private，子合约读写不到；但它把所有改动余额的路径
 * （transfer / transferFrom / _mint / _burn）都汇聚到 _update()，官方也指明"自定义应当覆盖
 * _update()"。如果只覆盖 balanceOf() 做换算、却沿用 OZ 原来的账本，就会出问题：账本里存的是
 * gons（约 1e51 量级），而 _update() 会把这个内部数字原样 emit 出去，于是 Transfer 事件金额
 * 和对外显示的余额对不上，钱包/浏览器会显示错误的转账数额。
 * 所以本合约整体替换账本：_update() 里把对外单位换算成 gons 记账，再以对外单位 emit 事件，
 * 做到"转多少就 emit 多少"。transfer / transferFrom / 授权逻辑则原样复用 OZ 的实现。
 *
 * ── 三、单位约定（全文统一） ──
 * 所有对外参数、返回值、event、授权额度都是 fragment（即 1e-18 枚的显示单位）；
 * 只有 _gonsBalances 里存的是 gons。
 * 授权额度不随 rebase 缩水：它是用户明确授予的具体数额，不参与通缩。
 */
contract RebaseToken is ERC20, Ownable {
    // ─────────────────────────── 常量 ───────────────────────────

    /// @dev uint256 的最大值 2^256 - 1。
    uint256 private constant MAX_UINT256 = type(uint256).max;

    /// @dev 初始发行量：1 亿枚（18 位小数）。
    uint256 private constant INITIAL_SUPPLY = 100_000_000 * 10 ** 18;

    /// @dev 恒定的 gons 总量。取「不超过 MAX_UINT256 且能被初始发行量整除」的最大值，好处有两个：
    /// 1) 初始 gonsPerFragment 是整数，铸造时 1:1 无损耗；
    /// 2) 因为 gonsPerFragment = TOTAL_GONS / totalSupply，任意 value ≤ totalSupply 都满足
    ///    value * gonsPerFragment ≤ TOTAL_GONS ≤ 2^256 - 1，换算永远不会溢出。
    uint256 private constant TOTAL_GONS = MAX_UINT256 - (MAX_UINT256 % INITIAL_SUPPLY);

    /// @dev 通缩比率分子：每次 rebase 后总量变成上一年的 99%。
    uint256 private constant DEFLATION_RATE = 99;

    /// @dev 通缩比率分母，与 DEFLATION_RATE 组合成 99/100。
    uint256 private constant RATE_DENOMINATOR = 100;

    /// @dev 两次自动 rebase 之间的最小间隔：365 天。
    uint256 private constant REBASE_INTERVAL = 365 days;

    // ─────────────────────────── 事件 / 错误 ───────────────────────────

    /// @dev rebase 完成：epoch 为第几次通缩，totalSupply 为通缩后的总量，gonsPerFragment 为新的汇率。
    event Rebase(uint256 indexed epoch, uint256 totalSupply, uint256 gonsPerFragment);

    /// @dev 距离上次 rebase 还不满一年，附带下一次可执行的时间戳。
    error RebaseTooEarly(uint256 nextRebaseTime);

    /// @dev 不支持铸造/销毁：本合约总量恒定，只由 rebase 逐年下调（_update 收到零地址时回滚）。
    error MintBurnNotSupported();

    // ─────────────────────────── 状态 ───────────────────────────

    /// @dev 内部账本：地址 => gons 数量。不随 rebase 变化，只在转账时变动。
    mapping(address account => uint256) private _gonsBalances;

    /// @dev 1 个 fragment 折算多少 gons。rebase 时调大，所以同样多的 gons 显示的余额更少。
    uint256 private _gonsPerFragment;

    /// @dev 对外显示的总供应量（fragment），每次 rebase 乘 99/100。
    uint256 private _totalFragments;

    /// @dev 上一次 rebase（或部署）的时间戳，用来判断是否已满一年。
    uint256 public lastRebaseTime;

    /// @dev 已执行的通缩次数；第 n 次 rebase 后总量为 INITIAL_SUPPLY * (0.99)^n。
    uint256 public rebaseEpoch;

    // ─────────────────────────── 部署 ───────────────────────────

    /**
     * @notice 部署合约，把全部初始发行量（1 亿枚）铸造给 initialOwner。
     * @param initialOwner 接收全部初始发行量、并且有权调用 manualRebase 的地址。
     * @dev TOTAL_GONS 能被 INITIAL_SUPPLY 整除，所以 gonsPerFragment 是精确整数，
     * 这一步等价于 1:1 铸造，没有取整损耗。
     */
    constructor(address initialOwner) ERC20("Rebase Deflation Token V2", "RDT2") Ownable(initialOwner) {
        _gonsPerFragment = TOTAL_GONS / INITIAL_SUPPLY;
        _totalFragments = INITIAL_SUPPLY;
        lastRebaseTime = block.timestamp;
        _gonsBalances[initialOwner] = TOTAL_GONS;

        // 按 ERC20 约定，铸造事件从零地址发出，金额用对外单位
        emit Transfer(address(0), initialOwner, INITIAL_SUPPLY);
    }

    // ─────────────────────────── 对外视图 ───────────────────────────

    /**
     * @notice 当前总供应量（对外单位），会随每个周年 rebase 逐年减少。
     * @dev 直接返回 _totalFragments，而不是由 gons 反算：
     * 因为 gonsPerFragment 是向下取整的除法，反算会引入 1 wei 级的尾差。
     * @return 通缩后的总量，单位为 1e-18 枚。
     */
    function totalSupply() public view override returns (uint256) {
        return _totalFragments;
    }

    /**
     * @notice 查询余额，已经按当前汇率折算，能直接反映通缩效果。
     * @dev balanceOf(user) = gons[user] / gonsPerFragment。整数除法向下取整，
     * 不足 1 个 fragment 的零头会留在原地址的 gons 里（不可花，也不影响总量）。
     * @param account 待查询地址。
     * @return 该地址当前可用的对外余额。
     */
    function balanceOf(address account) public view override returns (uint256) {
        return _gonsBalances[account] / _gonsPerFragment;
    }

    /// @notice 查询当前的 gons/fragment 汇率（rebase 后变大）。
    function gonsPerFragment() external view returns (uint256) {
        return _gonsPerFragment;
    }

    /// @notice 查询地址的原始 gons 余额（内部记账单位，不随 rebase 变化）。
    function gonsBalanceOf(address account) external view returns (uint256) {
        return _gonsBalances[account];
    }

    /// @notice 当前是否已满一年，可以执行 rebase。
    function canRebase() public view returns (bool) {
        return block.timestamp >= lastRebaseTime + REBASE_INTERVAL;
    }

    /// @notice 下一次允许自动 rebase 的时间戳。
    function nextRebaseTime() public view returns (uint256) {
        return lastRebaseTime + REBASE_INTERVAL;
    }

    // ─────────────────────────── 转账（唯一需要覆盖的账本入口） ───────────────────────────

    /**
     * @dev OZ 的 transfer / transferFrom / _mint / _burn 全都汇聚到 _update()，这是官方推荐的扩展点。
     * 这里把对外单位的 value 换算成 gons 记进自己的账本，再以对外单位 emit Transfer ——
     * 事件单位、balanceOf 单位、授权额度单位因此完全一致。
     * @param from 出资地址；零地址表示"铸造"，本合约不支持。
     * @param to 接收地址；零地址表示"销毁"，本合约不支持。
     * @param value 对外单位（fragment）数量。
     */
    function _update(address from, address to, uint256 value) internal override {
        // 只有在走 mint/burn 时 from 或 to 才会是零地址（普通转账在 OZ 的 _transfer 里已拦掉了）
        if (from == address(0) || to == address(0)) revert MintBurnNotSupported();

        uint256 fromGons = _gonsBalances[from];
        uint256 fromBalance = fromGons / _gonsPerFragment; // 先换算成对外余额再比较
        if (fromBalance < value) revert ERC20InsufficientBalance(from, fromBalance, value);

        // 余额检查已通过 => value ≤ 总供应量，因此 value * gonsPerFragment ≤ TOTAL_GONS，不会溢出
        uint256 gonValue = value * _gonsPerFragment;

        // gonValue = value * gonsPerFragment ≤ fromBalance * gonsPerFragment ≤ fromGons，不会下溢；
        // 所有地址的 gons 之和恒等于 TOTAL_GONS，也不会溢出。
        unchecked {
            _gonsBalances[from] = fromGons - gonValue;
            _gonsBalances[to] += gonValue;
        }

        emit Transfer(from, to, value);
    }

    // ─────────────────────────── 通缩 rebase ───────────────────────────

    /**
     * @notice 执行一次通缩：总量在上一年的基础上减少 1%。
     * @dev 任何人都可以调用（permissionless crank）：改动是确定性的、不需要信任，
     * 唯一的约束是距上次 rebase 必须满 365 天。不满一年会以 RebaseTooEarly 回滚。
     */
    function rebase() public {
        if (!canRebase()) revert RebaseTooEarly(nextRebaseTime());
        _rebase();
    }

    /**
     * @notice 跳过 365 天的时间限制，立即执行一次通缩。
     * @dev 仅 owner 可用，方便测试与演示；它会绕过年度节奏，属于特权入口，生产环境应谨慎。
     */
    function manualRebase() external onlyOwner {
        _rebase();
    }

    /**
     * @dev 通缩核心逻辑（三步）：
     * 1) 新总量 = 旧总量 * 99 / 100 —— 在"上一年总量"的基础上再降 1%，所以是复利通缩，
     *    整数除法会丢掉不足 1 wei 的余数，实际通缩量略多于 1%；
     * 2) 重算汇率 gonsPerFragment = TOTAL_GONS / 新总量：分子不变、分母变小，所以汇率变大；
     * 3) 各地址的 _gonsBalances 一个都没动 —— 但除数变大后，所有人的 balanceOf
     *    同时按同样的比例缩水，这就是"一次 rebase 全体通缩"的来源。
     * 注意：这里没有遍历任何用户，gas 是常数级的。
     */
    function _rebase() private {
        rebaseEpoch += 1;

        uint256 newTotalFragments = (_totalFragments * DEFLATION_RATE) / RATE_DENOMINATOR;
        _totalFragments = newTotalFragments;
        _gonsPerFragment = TOTAL_GONS / newTotalFragments;
        lastRebaseTime = block.timestamp;

        emit Rebase(rebaseEpoch, newTotalFragments, _gonsPerFragment);
    }
}
