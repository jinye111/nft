// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol";
import {RebaseToken} from "../src/RebaseToken.sol";

contract RebaseTokenTest is Test {
    uint256 private constant INITIAL_SUPPLY = 100_000_000 * 10 ** 18;
    uint256 private constant REBASE_INTERVAL = 365 days;

    RebaseToken private token;
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");

    function setUp() public {
        // 部署者(address(this))拿到全部 1 亿枚
        token = new RebaseToken(address(this));
        // 转 1000 万枚（10%）给 alice
        token.transfer(alice, 10_000_000 * 10 ** 18);
    }

    function test_InitialState() public view {
        assertEq(token.name(), "Rebase Deflation Token V2");
        assertEq(token.symbol(), "RDT2");
        assertEq(token.totalSupply(), INITIAL_SUPPLY);
        assertEq(token.balanceOf(address(this)), 90_000_000 * 10 ** 18);
        assertEq(token.balanceOf(alice), 10_000_000 * 10 ** 18);
        assertFalse(token.canRebase());
    }

    function test_RebaseRevertsBeforeOneYear() public {
        vm.expectRevert(
            abi.encodeWithSelector(RebaseToken.RebaseTooEarly.selector, token.nextRebaseTime())
        );
        token.rebase();
    }

    function test_RebaseAfterOneYearDeflatesOnePercent() public {
        uint256 gonsBefore = token.gonsBalanceOf(alice);
        uint256 gpfBefore = token.gonsPerFragment();
        uint256 balanceBefore = token.balanceOf(alice);

        vm.warp(token.nextRebaseTime());
        token.rebase();

        // 总量正好是上一年的 99%
        assertEq(token.totalSupply(), INITIAL_SUPPLY * 99 / 100);
        assertEq(token.rebaseEpoch(), 1);

        // 用户的 gons 一点没动（这才是 rebase 的关键：账本没变，汇率变了）
        assertEq(token.gonsBalanceOf(alice), gonsBefore);
        // 汇率变大 -> 同样多的 gons 显示更少的余额
        assertGt(token.gonsPerFragment(), gpfBefore);
        assertLt(token.balanceOf(alice), balanceBefore);

        // alice 持有 10% 的 gons，所以余额应该约等于新总量的 10%
        assertApproxEqRel(token.balanceOf(alice), token.totalSupply() / 10, 1e12);
        // 年化跌幅 1%，只允许极小的取整误差
        assertApproxEqRel(token.balanceOf(alice), 9_900_000 * 10 ** 18, 1e12);
    }

    function test_TwoYearsIsCompounded() public {
        vm.warp(token.nextRebaseTime());
        token.rebase();
        vm.warp(token.nextRebaseTime());
        token.rebase();

        // 在"上一年总量"的基础上再降 1% -> 0.99^2
        assertEq(token.rebaseEpoch(), 2);
        assertEq(token.totalSupply(), INITIAL_SUPPLY * 99 / 100 * 99 / 100);
    }

    /**
     * @dev 核心用例：rebase 之后，每个用户在界面/钱包上看到的余额是否正确。
     * 分五层验：
     * 1) 内部账本（gons）纹丝不动；
     * 2) 变的只有汇率 k；
     * 3) balanceOf 严格等于 gons / k 这条定义；
     * 4) 余额精确缩水到上一年的 99%；
     * 5) 缩水后的余额是"真"的 —— 想按旧数量花出去会被拒绝。
     *
     * 注：这里敢用 assertEq 做精确比较，是因为初始量 10^26 在早期能被 100 整除，
     * 前 13 次 rebase 的总量都是整数、99% 那一步没有截断；再往后（第 14 年起）
     * 会出现不足 1 wei 的截断，那时就该换成 assertApproxEqAbs 之类的近似断言。
     */
    function test_BalanceReflectsRebase() public {
        // 再加一个持有人，才能看出"所有人按同一比例缩水"而不是只有 alice 变了
        address carol = makeAddr("carol");
        token.transfer(carol, 20_000_000 * 10 ** 18); // 20%

        uint256 aliceGonsBefore = token.gonsBalanceOf(alice);
        uint256 carolGonsBefore = token.gonsBalanceOf(carol);
        uint256 kBefore = token.gonsPerFragment();
        uint256 aliceBefore = token.balanceOf(alice); // 1e25 = 1000 万枚
        uint256 carolBefore = token.balanceOf(carol); // 2e25 = 2000 万枚
        uint256 supplyBefore = token.totalSupply();

        // 时间快进到满一年，触发通缩
        vm.warp(token.nextRebaseTime());
        token.rebase();

        // 1) 内部账本一个数都没变
        assertEq(token.gonsBalanceOf(alice), aliceGonsBefore);
        assertEq(token.gonsBalanceOf(carol), carolGonsBefore);

        // 2) 变的只有汇率：分子 TOTAL_GONS 恒定、分母 supply 变小，所以 k 变大
        assertGt(token.gonsPerFragment(), kBefore);

        // 3) 对外余额就是 gons / k，逐 wei 对得上（这是 balanceOf 的定义式）
        assertEq(token.balanceOf(alice), aliceGonsBefore / token.gonsPerFragment());
        assertEq(token.balanceOf(carol), carolGonsBefore / token.gonsPerFragment());

        // 4) 余额精确缩水 1%，总量也是
        assertEq(token.balanceOf(alice), aliceBefore * 99 / 100);
        assertEq(token.balanceOf(carol), carolBefore * 99 / 100);
        assertEq(token.totalSupply(), supplyBefore * 99 / 100);

        // 5) 占比不变：10% 还是 10%，20% 还是 20%（留 1 wei 取整余量）
        assertApproxEqAbs(token.balanceOf(alice), token.totalSupply() / 10, 1);
        assertApproxEqAbs(token.balanceOf(carol), token.totalSupply() * 20 / 100, 1);

        // 6) 缩水后的余额是"真"的：拿 rebase 之前的旧数量去转，必须被拒绝
        vm.expectRevert();
        vm.prank(alice);
        token.transfer(bob, aliceBefore);
    }

    /// @dev 时间流逝本身不会改变余额：通缩只发生在 rebase 被调用的那一刻
    function test_BalanceStaysFlatBetweenRebases() public {
        uint256 before = token.balanceOf(alice);

        // 还差一天，不能 rebase，余额当然不变
        vm.warp(token.lastRebaseTime() + REBASE_INTERVAL - 1);
        assertFalse(token.canRebase());
        assertEq(token.balanceOf(alice), before);

        // 满一年了、但没人调用 rebase：余额依然一动不动
        vm.warp(token.nextRebaseTime());
        assertTrue(token.canRebase());
        assertEq(token.balanceOf(alice), before);

        // 只有真的调了 rebase，余额才变成 99%
        token.rebase();
        assertEq(token.balanceOf(alice), before * 99 / 100);
    }

    function test_TransferMovesDisplayAmountsAndEmitsDisplayUnits() public {
        vm.warp(token.nextRebaseTime());
        token.rebase();

        uint256 amount = 1_000_000 * 10 ** 18;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 bobBefore = token.balanceOf(bob);

        // 事件里的金额必须是"对外单位"，而不是 gons
        vm.expectEmit(true, true, true, true, address(token));
        emit IERC20.Transfer(alice, bob, amount);

        vm.prank(alice);
        token.transfer(bob, amount);

        // 通缩之后再转账，余额变动仍然精确等于请求的数量
        assertEq(token.balanceOf(alice), aliceBefore - amount);
        assertEq(token.balanceOf(bob), bobBefore + amount);
    }

    function test_TransferFromSpendsAllowance() public {
        uint256 amount = 500_000 * 10 ** 18;

        vm.prank(alice);
        token.approve(bob, amount);
        assertEq(token.allowance(alice, bob), amount);

        vm.prank(bob);
        token.transferFrom(alice, bob, amount);

        assertEq(token.allowance(alice, bob), 0);
        assertEq(token.balanceOf(bob), amount);

        // 额度不够必须回滚（额度检查走的是 OZ 原生逻辑）
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1)
        );
        vm.prank(bob);
        token.transferFrom(alice, bob, 1);
    }

    function test_TransferMoreThanBalanceReverts() public {
        uint256 tooMuch = token.balanceOf(alice) + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector,
                alice,
                token.balanceOf(alice),
                tooMuch
            )
        );
        vm.prank(alice);
        token.transfer(bob, tooMuch);
    }

    function test_ManualRebaseOnlyOwnerAndBypassesInterval() public {
        // 非 owner 不能手动通缩
        vm.prank(alice);
        vm.expectRevert();
        token.manualRebase();

        // owner 可以随时通缩（演示/测试用）
        uint256 before = token.totalSupply();
        token.manualRebase();
        assertEq(token.totalSupply(), before * 99 / 100);
    }

    /// @dev 不变量：gons 总量恒定、余额之和不超过总量（取整误差 < 1 wei，这里按 1e12 相对误差断言）
    function test_Invariant_GonsSumStaysConstant() public {
        uint256 gonsSumBefore = token.gonsBalanceOf(alice) + token.gonsBalanceOf(address(this));

        vm.warp(token.nextRebaseTime());
        token.rebase();

        // rebase 不改动任何地址的 gons，只改汇率
        uint256 gonsSumAfter = token.gonsBalanceOf(alice) + token.gonsBalanceOf(address(this));
        assertEq(gonsSumAfter, gonsSumBefore);

        // 所有地址的显示余额之和 ≈ 总量（差值来自整数取整，远小于 1 wei）
        uint256 displaySum = token.balanceOf(alice) + token.balanceOf(address(this));
        assertApproxEqRel(displaySum, token.totalSupply(), 1e12);
    }

    /**
     * @dev 打印用，不做断言：把通缩前后的余额换算成"枚"再 console 出来。
     * 跑法：forge test --match-test test_PrintBalancesBeforeAndAfterRebase -vv --skip "test/Bank.t.sol"
     * 注：这只是显示用的换算，真正的断言在 test_BalanceReflectsRebase 里。
     */
    function test_PrintBalancesBeforeAndAfterRebase() public {
        address carol = makeAddr("carol");
        token.transfer(carol, 20_000_000 * 10 ** 18); // 20%

        uint256 kBefore = token.gonsPerFragment();
        uint256 aliceGonsBefore = token.gonsBalanceOf(alice);
        uint256 carolGonsBefore = token.gonsBalanceOf(carol);
        uint256 ownerGonsBefore = token.gonsBalanceOf(address(this));

        console.log(unicode"========== 通缩前 ==========");
        _printSnapshot(carol, kBefore);

        vm.warp(token.nextRebaseTime());
        token.rebase();

        console.log(unicode"========== 通缩后 ==========");
        _printSnapshot(carol, kBefore);

        // 内部账本一个数都没动，期望打印 false false false
        console.log(string.concat(
            unicode"gons 是否变化 alice/carol/owner: ",
            vm.toString(token.gonsBalanceOf(alice) != aliceGonsBefore), " ",
            vm.toString(token.gonsBalanceOf(carol) != carolGonsBefore), " ",
            vm.toString(token.gonsBalanceOf(address(this)) != ownerGonsBefore)
        ));
    }

    /// @dev 每个地址一行：对外余额（枚）+ 占总量百分比；汇率 k 用"相对上次的倍数"表示
    function _printSnapshot(address carol, uint256 kBaseline) private view {
        uint256 supply = token.totalSupply();

        console.log(string.concat(unicode"总量:        ", _fmt(supply, 18), " RDT"));
        _printHolder(unicode"alice 余额:  ", alice, supply);
        _printHolder(unicode"carol 余额:  ", carol, supply);
        _printHolder(unicode"owner 余额:  ", address(this), supply);
        console.log(string.concat(unicode"汇率 k 倍数: ", _fmt(token.gonsPerFragment() * 1e6 / kBaseline, 6)));
    }

    function _printHolder(string memory label, address who, uint256 supply) private view {
        uint256 balance = token.balanceOf(who);
        console.log(string.concat(
            label, _fmt(balance, 18), " RDT  (",
            _fmt(balance * 100e6 / supply, 6), unicode"%)"
        ));
    }

    /// @dev wei -> "整数.小数" 字符串，纯显示用（截断，不四舍五入）
    function _fmt(uint256 value, uint256 decimals) private pure returns (string memory) {
        uint256 unit = 10 ** decimals;
        return string.concat(vm.toString(value / unit), ".", _padLeft(vm.toString(value % unit), decimals));
    }

    /// @dev 字符串左边补零到指定宽度，保证小数部分位数对齐
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
