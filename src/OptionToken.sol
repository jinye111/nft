// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/**
 * @title OptionToken —— ETH 看涨期权 Token（欧式 / 全额抵押 / 实物交割）
 * @notice 1 份期权（1e18）= 「到期日当天，以 strikePrice 的价格买入 1 ETH」的权利。
 *
 * ── 谁做什么 ──
 * 项目方（owner，期权卖方）：
 *   1) 部署时确定行权价与到期日；
 *   2) 把 ETH 转入合约当抵押，1:1 铸出期权 Token；
 *   3) 把期权按"期权费"卖给用户（本合约用一个简化的挂单撮合来模拟，见 buyOptions）；
 *   4) 到期日结束后收回没被行权的抵押 ETH。
 * 用户（期权买方）：
 *   1) 花 USDT 买入期权（期权费低于行权价，这就是它的杠杆所在）；
 *   2) 到期日当天，按行权价支付 USDT 换出 ETH，期权随即被销毁。
 *
 * ── 为什么持有期权可能赚钱 ──
 * 假设行权价 2000 USDT、期权费 100 USDT。到期日若 ETH 市价 2500：
 * 花 2000 USDT 行权拿到 1 ETH（值 2500），减去买期权的 100，净赚 400。
 * 若到期日 ETH 市价只有 1800，行权就是亏的 —— 用户可以选择不行权，
 * 损失上限就是那 100 USDT 期权费（这正是期权"亏损有限、收益无限"的含义）。
 *
 * ── 关键规则 ──
 * 1) 行权窗口只有到期日当天：[expiry, expiry + 1 days)，过期即作废（欧式期权的定义）；
 * 2) 抵押率 100%：ETH 抵押量始终等于已发行期权量，任何人来行权都拿得出币，不会挤兑；
 * 3) 行权收到的 USDT 直接转给项目方（期权卖方），不停留在合约里；
 * 4) 未被行权的期权到期后归零，对应的抵押 ETH 归项目方所有 —— 这是卖方的利润来源。
 */
contract OptionToken is ERC20, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ─────────────────────────── 期权条款（部署时确定，之后不可改） ───────────────────────────

    /// @dev 行权价的计价币（USDT）。
    IERC20 public immutable usdt;

    /// @dev 行权价：买 1 ETH（= 1e18 份期权）需要支付多少 USDT（按 USDT 的最小单位计）。
    uint256 public immutable strikePrice;

    /// @dev 到期日（时间戳，通常取当天 0 点）。行权窗口是 [expiry, expiry + 1 days)。
    uint256 public immutable expiry;

    /// @dev 行权窗口结束时刻 = expiry + 1 days，过了这个点期权作废。
    uint256 public immutable expiryWindowEnd;

    // ─────────────────────────── 可调参数与状态 ───────────────────────────

    /// @dev 期权费：买 1 ETH 份额的期权要付多少 USDT。0 表示未开启售卖。
    uint256 public salePrice;

    /// @dev 是否已完成结算（结算后不能再行权）。
    bool public settled;

    // ─────────────────────────── 事件 ───────────────────────────

    /// @dev 发行：项目方转入 ethIn 的 ETH，铸出 optionOut 份期权。
    event Issued(address indexed issuer, uint256 ethIn, uint256 optionOut);

    /// @dev 用户买入期权：支付 usdtPaid 的期权费，拿到 optionAmount 份期权。
    event OptionPurchased(address indexed buyer, uint256 optionAmount, uint256 usdtPaid);

    /// @dev 行权：用户支付 usdtPaid 的行权价，销毁 optionAmount 份期权，取走等量 ETH。
    event Exercised(address indexed user, uint256 optionAmount, uint256 usdtPaid, uint256 ethOut);

    /// @dev 结算：项目方销毁 optionBurned 份剩余期权，赎回 ethOut 的抵押 ETH。
    event Settled(address indexed seller, uint256 ethOut, uint256 optionBurned);

    /// @dev 期权费调整。
    event SalePriceUpdated(uint256 newSalePrice);

    // ─────────────────────────── 错误 ───────────────────────────

    error InvalidAddress();
    error InvalidTerms();
    error AlreadyExpired();
    error NotExpiredYet();
    error SaleNotOpen();
    error ZeroAmount();
    error NotInExerciseWindow(uint256 now_, uint256 windowStart, uint256 windowEnd);
    error AlreadySettled();
    error EthTransferFailed();

    /**
     * @notice 创建期权：确定标的（ETH）的行权价与到期日。
     * @param usdt_ 行权价计价币（USDT）地址。
     * @param strikePrice_ 行权价：买 1 ETH 需要多少 USDT（按 USDT 最小单位，例如 2000 USDT 传 2000e6）。
     * @param expiry_ 到期日时间戳，必须晚于当前时间。
     * @param seller 期权卖方（项目方），同时是合约 owner。
     */
    constructor(address usdt_, uint256 strikePrice_, uint256 expiry_, address seller)
        ERC20("ETH Call Option", "oETH")
        Ownable(seller)
    {
        if (usdt_ == address(0)) revert InvalidAddress();
        if (strikePrice_ == 0 || expiry_ <= block.timestamp) revert InvalidTerms();

        usdt = IERC20(usdt_);
        strikePrice = strikePrice_;
        expiry = expiry_;
        expiryWindowEnd = expiry_ + 1 days;
    }

    // ─────────────────────────── 项目方：发行 ───────────────────────────

    /**
     * @notice 项目方转入标的（ETH）作为抵押，1:1 铸出期权 Token。
     * @dev 抵押与期权数量严格 1:1：收到 1 wei ETH 就铸 1 wei 期权，
     * 因为 1 份期权对应 1 wei ETH 的购买权，这样任何持有者都一定能行权成功。
     * @return optionAmount 铸出的期权数量。
     */
    function issue() external payable onlyOwner nonReentrant returns (uint256 optionAmount) {
        if (block.timestamp >= expiry) revert AlreadyExpired();
        if (msg.value == 0) revert ZeroAmount();

        optionAmount = msg.value;
        _mint(msg.sender, optionAmount);

        emit Issued(msg.sender, msg.value, optionAmount);
    }

    /// @notice 项目方设置期权费（每个 1 ETH 份额的期权卖多少 USDT）；传 0 表示暂停售卖。
    function setSalePrice(uint256 newSalePrice) external onlyOwner {
        salePrice = newSalePrice;
        emit SalePriceUpdated(newSalePrice);
    }

    // ─────────────────────────── 用户：买入期权 ───────────────────────────

    /**
     * @notice 用户按期权费从项目方的挂单里买入期权。
     * @dev 这是对"期权 Token / USDT 交易对"的简化模拟：真实项目里这一层通常是一个 AMM 池子
     * （比如 Uniswap V2 上开一个 oETH/USDT 池），价格由池子决定而不是由项目方设定。
     * 项目方先把期权转到本合约地址（转给合约即完成挂单），用户买入时从合约库存里发货，
     * 收到的 USDT 直接转给项目方。
     * @param optionAmount 想买多少份期权（1e18 = 1 ETH 份额）。
     * @return usdtPaid 实际支付的 USDT 数量。
     */
    function buyOptions(uint256 optionAmount) external nonReentrant returns (uint256 usdtPaid) {
        if (salePrice == 0) revert SaleNotOpen();
        if (block.timestamp >= expiry) revert AlreadyExpired();
        if (optionAmount == 0) revert ZeroAmount();

        // 期权费 = 份数 * 单价 / 1e18（份数与单价都是按最小单位计的整数）
        usdtPaid = (optionAmount * salePrice) / 1e18;

        // 先收款再发货（CEI）；库存不足时整个交易回滚，用户不会白付钱
        usdt.safeTransferFrom(msg.sender, owner(), usdtPaid);
        _transfer(address(this), msg.sender, optionAmount);

        emit OptionPurchased(msg.sender, optionAmount, usdtPaid);
    }

    // ─────────────────────────── 用户：行权 ───────────────────────────

    /**
     * @notice 到期日当天，按行权价支付 USDT，换出等量 ETH，期权被销毁。
     * @dev 只在 [expiry, expiry + 1 days) 内可调用；过期作废，一分钱也拿不回来。
     * 顺序上先收钱、再销毁期权、最后转 ETH（CEI，配合 nonReentrant 防重入）。
     * @param optionAmount 要行权的期权数量（1e18 = 1 ETH）。
     */
    function exercise(uint256 optionAmount) external nonReentrant {
        if (settled) revert AlreadySettled();

        // 欧式期权：只能在到期日当天行权
        if (block.timestamp < expiry || block.timestamp >= expiryWindowEnd) {
            revert NotInExerciseWindow(block.timestamp, expiry, expiryWindowEnd);
        }
        if (optionAmount == 0) revert ZeroAmount();

        // 行权价 = 份数 * 单价 / 1e18，直接付给项目方
        uint256 cost = (optionAmount * strikePrice) / 1e18;
        usdt.safeTransferFrom(msg.sender, owner(), cost);

        // 期权兑现后即销毁，对应的抵押 ETH 释放给用户
        _burn(msg.sender, optionAmount);

        (bool ok,) = msg.sender.call{value: optionAmount}("");
        if (!ok) revert EthTransferFailed();

        emit Exercised(msg.sender, optionAmount, cost, optionAmount);
    }

    // ─────────────────────────── 项目方：到期结算 ───────────────────────────

    /**
     * @notice 到期日结束后，项目方销毁手里剩余的期权，赎回没被行权的抵押 ETH。
     * @dev 销毁的范围只有本合约自己能支配的两个余额：
     * 1) 合约地址持有的部分，也就是挂单还没卖掉的库存；
     * 2) 项目方自己钱包里的部分。
     * 用户手里那些没行权的期权无法被强制销毁（链上没法遍历所有持有者），
     * 它们会自然作废：既不能行权，也不值钱；用户可以用 burnExpired() 自己清理掉。
     * 注意赎回的 ETH 不一定等于销毁的期权数量：第三方那些没行权的期权虽然烧不掉，
     * 它们背后的抵押同样归项目方 —— 这正是期权卖方的利润来源。
     */
    function settle() external onlyOwner nonReentrant {
        if (block.timestamp < expiryWindowEnd) revert NotExpiredYet();
        if (settled) revert AlreadySettled();
        settled = true;

        // 销毁项目方可控的剩余期权。两个来源分开处理，缺一不可：
        // - inventory：合约地址持有的余额，即挂单还没卖掉的库存。
        //   它就是 balanceOf(address(this))，所以若有人误把期权转到合约地址，也会被算进来。
        //   （误转发生在到期前的话，这些期权会被 buyOptions 当成库存卖给别的用户。）
        // - own：项目方自己钱包里的余额。
        // 合约烧的是自己在账本上的余额，动不了任何第三方钱包；此刻行权窗口已关闭，
        // 被烧的期权都已作废，不影响任何有效权利。
        uint256 inventory = balanceOf(address(this));
        uint256 own = balanceOf(msg.sender);
        if (inventory > 0) _burn(address(this), inventory);
        if (own > 0) _burn(msg.sender, own);

        // 剩下的抵押 ETH 全部归项目方（= 没被行权的期权对应的抵押）
        uint256 ethOut = address(this).balance;
        (bool ok,) = msg.sender.call{value: ethOut}("");
        if (!ok) revert EthTransferFailed();

        emit Settled(msg.sender, ethOut, inventory + own);
    }

    /**
     * @notice 过期后，任何人烧掉自己钱包里已作废的期权（清库存用）。
     * @dev 这些期权在到期日后已经一文不值，烧掉只是让账面上干净些。
     */
    function burnExpired() external {
        if (block.timestamp < expiryWindowEnd) revert NotExpiredYet();
        uint256 amount = balanceOf(msg.sender);
        if (amount == 0) revert ZeroAmount();
        _burn(msg.sender, amount);
    }

    // ─────────────────────────── 查询 ───────────────────────────

    /// @notice 合约里锁着的抵押 ETH 数量。
    function collateral() external view returns (uint256) {
        return address(this).balance;
    }

    /// @notice 当前是否可以行权。
    function canExercise() external view returns (bool) {
        return !settled && block.timestamp >= expiry && block.timestamp < expiryWindowEnd;
    }

    /// @notice 行权 optionAmount 份期权需要支付多少 USDT。
    function costToExercise(uint256 optionAmount) external view returns (uint256) {
        return (optionAmount * strikePrice) / 1e18;
    }

    /// @notice 行权 optionAmount 份期权需要支付多少 USDT 的期权费。
    function costToBuy(uint256 optionAmount) external view returns (uint256) {
        return (optionAmount * salePrice) / 1e18;
    }
}
