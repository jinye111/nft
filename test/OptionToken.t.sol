// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {OptionToken} from "../src/OptionToken.sol";

/// @dev 测试用的 USDT：6 位小数（和真实 USDT 一致），谁都能 mint
contract MockUSDT is ERC20 {
    constructor() ERC20("Mock USDT", "USDT") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract OptionTokenTest is Test {
    // ── 期权条款 ──
    uint256 private constant STRIKE = 2000e6; // 行权价：2000 USDT / ETH
    uint256 private constant PREMIUM = 100e6; // 期权费：100 USDT / 份（远低于行权价）

    // ── 各方的动作 ──
    uint256 private constant ISSUE_ETH = 10 ether; // 项目方抵押 10 ETH
    uint256 private constant INVENTORY = 5 ether; // 拿 5 份去挂单卖
    uint256 private constant ALICE_BUY = 2 ether; // alice 买 2 份

    MockUSDT private usdt;
    OptionToken private option;

    address private project = makeAddr("project");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    uint256 private expiry;

    function setUp() public {
        // 固定起始时间，让日志里的时间戳可读
        vm.warp(1_700_000_000); // 2023-11-14 22:13:20 UTC
        expiry = block.timestamp + 30 days;

        usdt = new MockUSDT();
        option = new OptionToken(address(usdt), STRIKE, expiry, project);

        // 项目方准备 ETH（要拿去抵押），alice/bob 准备 USDT（要拿来买期权和行权）
        vm.deal(project, 100 ether);
        usdt.mint(project, 1_000_000e6);
        usdt.mint(alice, 1_000_000e6);
        usdt.mint(bob, 1_000_000e6);
    }

    // ─────────────────────────── ① 发行 ───────────────────────────

    function test_Issue_MintsOptionsOneToOne() public {
        vm.prank(project);
        uint256 minted = option.issue{value: ISSUE_ETH}();

        console.log(unicode"===== ① 项目方发行期权 =====");
        console.log(string.concat(unicode"转入的标的       : ", _fmt(ISSUE_ETH, 18), " ETH"));
        console.log(string.concat(unicode"铸出的期权       : ", _fmt(minted, 18), unicode" 份"));
        console.log(string.concat(unicode"合约抵押的 ETH   : ", _fmt(option.collateral(), 18), " ETH"));
        console.log(string.concat(unicode"期权总量         : ", _fmt(option.totalSupply(), 18), unicode" 份"));
        _printTerms();

        // 抵押与期权 1:1
        assertEq(minted, ISSUE_ETH);
        assertEq(option.balanceOf(project), ISSUE_ETH);
        assertEq(option.collateral(), ISSUE_ETH);
    }

    // ─────────────────────────── ② 用户买入期权 ───────────────────────────

    function test_BuyOptions_PaysPremiumOnly() public {
        vm.prank(project);
        option.issue{value: ISSUE_ETH}();

        // 项目方把 5 份期权转到合约地址，等于在池子里挂单
        vm.prank(project);
        option.transfer(address(option), INVENTORY);
        vm.prank(project);
        option.setSalePrice(PREMIUM);

        uint256 aliceUsdtBefore = usdt.balanceOf(alice);

        vm.prank(alice);
        usdt.approve(address(option), type(uint256).max);
        vm.prank(alice);
        uint256 paid = option.buyOptions(ALICE_BUY);

        console.log(unicode"===== ② alice 买入期权 =====");
        console.log(string.concat(unicode"付出期权费       : ", _fmt(paid, 6), " USDT"));
        console.log(string.concat(unicode"拿到的期权       : ", _fmt(option.balanceOf(alice), 18), unicode" 份"));
        console.log(string.concat(unicode"合约里剩余库存   : ", _fmt(option.balanceOf(address(option)), 18), unicode" 份"));
        console.log(string.concat(unicode"项目方收到的 USDT: ", _fmt(usdt.balanceOf(project) - 1_000_000e6, 6), " USDT"));
        console.log(string.concat(unicode"alice 剩下的 USDT: ", _fmt(usdt.balanceOf(alice), 6), " USDT"));

        // 期权费 = 2 份 * 100 USDT = 200 USDT（比行权价 4000 USDT 便宜得多）
        assertEq(paid, 200e6);
        assertEq(usdt.balanceOf(alice), aliceUsdtBefore - paid);
        assertEq(option.balanceOf(alice), ALICE_BUY);
    }

    // ─────────────────────────── ③ 到期日行权 ───────────────────────────

    function test_Exercise_PaysStrikeAndReceivesETH() public {
        _issueAndSell();

        uint256 aliceEthBefore = alice.balance;
        uint256 aliceUsdtBefore = usdt.balanceOf(alice);
        uint256 projectUsdtBefore = usdt.balanceOf(project);
        uint256 collateralBefore = option.collateral();

        // 快进到到期日
        vm.warp(expiry);
        vm.prank(alice);
        option.exercise(ALICE_BUY);

        console.log(unicode"===== ③ 到期日 alice 行权 =====");
        console.log(string.concat(unicode"行权时间         : ", vm.toString(block.timestamp), unicode"（到期日当天）"));
        console.log(string.concat(unicode"行权价           : ", _fmt(STRIKE, 6), " USDT / ETH"));
        console.log(string.concat(unicode"支付的 USDT      : ", _fmt(aliceUsdtBefore - usdt.balanceOf(alice), 6)));
        console.log(string.concat(unicode"销毁的期权       : ", _fmt(ALICE_BUY, 18), unicode" 份"));
        console.log(string.concat(unicode"收到的 ETH       : ", _fmt(alice.balance - aliceEthBefore, 18)));
        console.log(string.concat(unicode"alice 现在持有   : ", _fmt(alice.balance, 18), " ETH + ", _fmt(usdt.balanceOf(alice), 6), " USDT"));
        console.log(string.concat(unicode"项目方收到的行权价: ", _fmt(usdt.balanceOf(project) - projectUsdtBefore, 6), " USDT"));
        console.log(string.concat(unicode"合约剩余抵押     : ", _fmt(option.collateral(), 18), unicode" ETH（从 ", _fmt(collateralBefore, 18), unicode" 减少）"));

        // 付了 2 * 2000 = 4000 USDT，拿回 2 ETH，期权被销毁
        assertEq(alice.balance, aliceEthBefore + ALICE_BUY);
        assertEq(aliceUsdtBefore - usdt.balanceOf(alice), 4000e6);
        assertEq(option.balanceOf(alice), 0);
        assertEq(option.collateral(), collateralBefore - ALICE_BUY);
    }

    function test_Exercise_OnlyOnExpiryDay() public {
        _issueAndSell();

        // 到期前一天：不能行权
        vm.warp(expiry - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionToken.NotInExerciseWindow.selector, expiry - 1, expiry, expiry + 1 days
            )
        );
        option.exercise(ALICE_BUY);

        // 到期日当天：可以行权
        vm.warp(expiry);
        vm.prank(alice);
        option.exercise(ALICE_BUY);
        assertEq(alice.balance, ALICE_BUY);

        // 到期日结束：作废
        vm.warp(expiry + 1 days);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                OptionToken.NotInExerciseWindow.selector, expiry + 1 days, expiry, expiry + 1 days
            )
        );
        option.exercise(1 ether);
    }

    // ─────────────────────────── ④ 过期结算 ───────────────────────────

    function test_Settle_RedeemsUnexercisedCollateral() public {
        _issueAndSell();

        // alice 在到期日只行权 1 份，剩 1 份作废
        vm.warp(expiry);
        vm.prank(alice);
        option.exercise(1 ether);

        uint256 projectEthBefore = project.balance;
        uint256 collateralAfterExercise = option.collateral();

        // 行权窗口结束后，项目方结算
        vm.warp(expiry + 1 days);
        vm.prank(project);
        option.settle();

        console.log(unicode"===== ④ 到期后项目方结算 =====");
        console.log(unicode"alice 只行权了   : 1 份，剩下 1 份作废");
        console.log(string.concat(unicode"结算前未行权抵押 : ", _fmt(collateralAfterExercise, 18), " ETH"));
        console.log(string.concat(unicode"项目方赎回的 ETH : ", _fmt(project.balance - projectEthBefore, 18)));
        console.log(string.concat(unicode"项目方剩余 ETH   : ", _fmt(project.balance, 18)));
        console.log(string.concat(unicode"销毁的剩余期权   : 项目方 5 份 + 库存 3 份"));
        console.log(string.concat(unicode"合约剩余抵押     : ", _fmt(option.collateral(), 18), " ETH"));
        console.log(string.concat(unicode"alice 手里的期权 : ", _fmt(option.balanceOf(alice), 18), unicode" 份（已成废纸）"));

        // 10 ETH 抵押 - 1 ETH 已行权 = 9 ETH 回到项目方
        assertEq(project.balance, projectEthBefore + 9 ether);
        assertEq(option.balanceOf(project), 0);
        assertEq(option.balanceOf(address(option)), 0);
        assertEq(option.collateral(), 0);
        assertTrue(option.settled());
    }

    /// @dev 项目方专属的三个入口，普通用户来调一律回滚
    function test_NormalUserCannotCallOwnerFunctions() public {
        bytes memory unauthorized =
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);

        // 1) 发行：普通用户不能铸期权
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(unauthorized);
        option.issue{value: 1 ether}();

        // 2) 定价：普通用户不能改期权费
        vm.prank(alice);
        vm.expectRevert(unauthorized);
        option.setSalePrice(PREMIUM);

        // 3) 结算：哪怕已经过期，普通用户也拿不走抵押的 ETH
        _issueAndSell();
        vm.warp(expiry + 1 days);
        vm.prank(alice);
        vm.expectRevert(unauthorized);
        option.settle();

        // 三次回滚之后，抵押和项目方余额原封不动
        assertEq(option.collateral(), ISSUE_ETH);
        assertEq(project.balance, 90 ether);
    }

    function test_ExpiredOptionsAreWorthless() public {
        _issueAndSell();

        vm.warp(expiry + 1 days);

        // 过期后行权被拒绝
        vm.prank(alice);
        vm.expectRevert();
        option.exercise(ALICE_BUY);

        // 用户可以把作废的期权自己烧掉
        vm.prank(alice);
        option.burnExpired();
        assertEq(option.balanceOf(alice), 0);
    }

    // ─────────────────────────── 内部工具 ───────────────────────────

    /// @dev 走完"发行 -> 挂单 -> alice 买入"三步，得到一份手续齐全的期权市场
    function _issueAndSell() private {
        vm.prank(project);
        option.issue{value: ISSUE_ETH}();
        vm.prank(project);
        option.transfer(address(option), INVENTORY);
        vm.prank(project);
        option.setSalePrice(PREMIUM);

        vm.prank(alice);
        usdt.approve(address(option), type(uint256).max);
        vm.prank(alice);
        option.buyOptions(ALICE_BUY);
    }

    function _printTerms() private view {
        console.log(string.concat(unicode"标的             : ETH"));
        console.log(string.concat(unicode"行权价           : ", _fmt(STRIKE, 6), " USDT / ETH"));
        console.log(string.concat(unicode"到期日           : ", vm.toString(expiry)));
        console.log(string.concat(unicode"行权窗口         : ", vm.toString(expiry), " ~ ", vm.toString(expiry + 1 days)));
    }

    /// @dev wei/最小单位 -> "整数.小数" 字符串，纯显示用（截断，不四舍五入）
    function _fmt(uint256 value, uint256 decimals) private pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        return string.concat(vm.toString(value / unit), ".", _padLeft(vm.toString(value % unit), decimals));
    }

    /// @dev 字符串左边补零到指定宽度，让小数位数对齐
    function _padLeft(string memory s, uint256 width) private pure returns (string memory) {
        bytes memory b = bytes(s);
        if (b.length >= width) return s;
        bytes memory padding = new bytes(width - b.length);
        for (uint256 i = 0; i < padding.length; ++i) {
            padding[i] = "0";
        }
        return string.concat(string(padding), s);
    }
}
