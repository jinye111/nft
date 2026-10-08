// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Vesting} from "../src/Vesting.sol";

/// @dev 测试用 ERC20：部署者拿到 1000 万枚，用于给 Vesting 转入 100 万枚。
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MOCK") {
        _mint(msg.sender, 10_000_000e18);
    }
}

contract VestingTest is Test {
    /// @dev 与 Vesting（OpenZeppelin VestingWallet）里同名的事件，用于校验 release() 的日志。
    event ERC20Released(address indexed token, uint256 amount);

    /// @dev 一个月按 30 天计算，12 个月 Cliff + 24 个月线性释放。
    uint64 internal constant MONTH = 30 days;
    uint64 internal constant CLIFF = 12 * MONTH; // 第 12 个月结束（Cliff 结束点）
    uint64 internal constant LINEAR = 24 * MONTH; // 线性释放期：第 13 ~ 36 个月
    uint64 internal constant TOTAL = CLIFF + LINEAR; // 整个解锁周期：36 个月

    uint256 internal constant LOCKED = 1_000_000e18; // 100 万 ERC20
    uint64 internal constant DEPLOY_TIME = 1_700_000_000; // 固定部署时间，便于时间模拟

    MockERC20 internal token;
    Vesting internal vesting;
    address internal beneficiary = makeAddr("beneficiary");

    function setUp() public {
        // 让部署时间固定下来，Cliff / 线性释放的时间点才可预期。
        vm.warp(DEPLOY_TIME);
        token = new MockERC20();
        vesting = new Vesting(beneficiary, token);

        // 部署后转入 100 万 ERC20，Cliff 从部署时刻开始计算。
        assertTrue(token.approve(address(vesting), LOCKED));
        vesting.fund();
    }

    /// @dev 当前区块时间（测试里的时间戳远小于 uint64 上限，窄化转换安全）。
    function _now() internal view returns (uint64) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint64(block.timestamp);
    }

    /// @dev 把时间推进到部署后的第 `month` 个月。
    function _warpToMonth(uint64 month) internal {
        vm.warp(DEPLOY_TIME + uint256(month) * MONTH);
    }

    // ---------------------------------------------------------------------
    // 部署 / 初始化
    // ---------------------------------------------------------------------

    function test_InitialStateStartsCliffAtDeployment() public view {
        assertEq(vesting.beneficiary(), beneficiary, "beneficiary mismatch");
        assertEq(address(vesting.token()), address(token), "locked token mismatch");

        // 部署即开始计算 Cliff
        assertEq(vesting.start(), DEPLOY_TIME, "start should be deploy time");
        assertEq(vesting.cliff(), DEPLOY_TIME + CLIFF, "cliff should be 12 months");
        assertEq(vesting.duration(), TOTAL, "duration should be 36 months");
        assertEq(vesting.end(), DEPLOY_TIME + TOTAL, "end should be 36 months");

        // 100 万 ERC20 已转入，且此刻没有任何代币解锁
        assertEq(token.balanceOf(address(vesting)), LOCKED, "locked amount mismatch");
        assertEq(vesting.vestedTokenAmount(DEPLOY_TIME), 0);
        assertEq(vesting.releasableToken(), 0);
    }

    function test_RevertWhenBeneficiaryIsZeroAddress() public {
        vm.expectRevert(Vesting.InvalidBeneficiary.selector);
        new Vesting(address(0), token);
    }

    function test_RevertWhenTokenIsZeroAddress() public {
        vm.expectRevert(Vesting.InvalidTokenAddress.selector);
        new Vesting(beneficiary, IERC20(address(0)));
    }

    function test_FundTransfersExactlyOneMillionTokens() public {
        MockERC20 otherToken = new MockERC20();
        address funder = makeAddr("funder");
        assertTrue(otherToken.transfer(funder, LOCKED));

        Vesting otherVesting = new Vesting(beneficiary, otherToken);

        vm.startPrank(funder);
        assertTrue(otherToken.approve(address(otherVesting), LOCKED));
        otherVesting.fund();
        vm.stopPrank();

        assertEq(otherToken.balanceOf(address(otherVesting)), LOCKED);
        assertEq(otherToken.balanceOf(funder), 0);
    }

    function test_FundRevertsWithoutApproval() public {
        Vesting otherVesting = new Vesting(beneficiary, token);

        // 测试合约持有代币，但没有 approve 新的 Vesting 合约。
        vm.expectRevert();
        otherVesting.fund();
    }

    function test_FundZeroReverts() public {
        vm.expectRevert(Vesting.ZeroAmount.selector);
        vesting.fund(0);
    }

    function test_TransferTokensDirectlyIsAlsoSupported() public {
        Vesting otherVesting = new Vesting(beneficiary, token);

        assertTrue(token.transfer(address(otherVesting), LOCKED));

        assertEq(token.balanceOf(address(otherVesting)), LOCKED);
        assertEq(otherVesting.releasableToken(), 0, "still locked during cliff");
    }

    // ---------------------------------------------------------------------
    // Cliff：第 1 ~ 12 个月不解锁
    // ---------------------------------------------------------------------

    function test_NoTokensUnlockBeforeCliff() public {
        _warpToMonth(1);
        assertEq(vesting.releasableToken(), 0);

        _warpToMonth(6);
        assertEq(vesting.releasableToken(), 0);

        // Cliff 结束前 1 秒仍然为 0
        vm.warp(DEPLOY_TIME + CLIFF - 1);
        assertEq(vesting.vestedTokenAmount(_now()), 0);
        assertEq(vesting.releasableToken(), 0);
    }

    function test_CliffEndsWithZeroUnlocked() public {
        // Cliff 结束的瞬间刚好是 0 个解锁（线性释放从这一刻之后开始）
        vm.warp(DEPLOY_TIME + CLIFF);
        assertEq(vesting.vestedTokenAmount(_now()), 0);
        assertEq(vesting.releasableToken(), 0);
    }

    function test_ReleaseDuringCliffTransfersNothing() public {
        _warpToMonth(11);

        vesting.release();

        assertEq(token.balanceOf(beneficiary), 0);
        assertEq(token.balanceOf(address(vesting)), LOCKED);
        assertEq(vesting.released(address(token)), 0);
    }

    // ---------------------------------------------------------------------
    // 线性释放：第 13 个月起每月解锁 1/24
    // ---------------------------------------------------------------------

    function test_FirstUnlockAtMonth13IsOneTwentyFourth() public {
        _warpToMonth(13);

        uint256 expected = LOCKED / 24;
        assertEq(vesting.releasableToken(), expected, "month 13 should unlock 1/24");

        vm.expectEmit(true, false, false, true, address(vesting));
        emit ERC20Released(address(token), expected);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), expected);
        assertEq(token.balanceOf(address(vesting)), LOCKED - expected);
        assertEq(vesting.released(address(token)), expected);
        assertEq(vesting.releasableToken(), 0, "nothing left until next month");
    }

    function test_ReleaseAndReleaseAddressShareTheSameLedger() public {
        _warpToMonth(13);
        vesting.release(); // release() 走自实现的转账逻辑
        uint256 firstClaim = token.balanceOf(beneficiary);
        assertEq(firstClaim, LOCKED / 24);

        // 带参版本也走同一套账本：同一时间点重复领取不会重复发放
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), firstClaim);
        assertEq(vesting.released(address(token)), firstClaim);

        // 一个月后再用 release(address) 领取，只会拿到新解锁的 1/24
        _warpToMonth(14);
        vesting.release(address(token));
        assertEq(token.balanceOf(beneficiary), (LOCKED * 2) / 24);
        assertEq(vesting.released(address(token)), (LOCKED * 2) / 24);
        assertEq(vesting.releasableToken(), 0);
    }

    function test_MonthlyUnlockOneTwentyFourthUntilFullyVested() public {
        for (uint64 month = 1; month <= 24; ++month) {
            _warpToMonth(12 + month);

            uint256 vested = (LOCKED * month) / 24;
            assertEq(vesting.vestedTokenAmount(_now()), vested, "vested mismatch");

            // 时间模拟：每月调用一次 release()，只能拿到当月新解锁的 1/24
            vesting.release();
            assertEq(token.balanceOf(beneficiary), vested, "claimable mismatch");
        }

        // 第 36 个月：24/24 全部解锁
        assertEq(token.balanceOf(beneficiary), LOCKED);
        assertEq(token.balanceOf(address(vesting)), 0);
        assertEq(vesting.releasableToken(), 0);
    }

    function test_AnyoneCanTriggerReleaseButOnlyBeneficiaryReceives() public {
        _warpToMonth(13);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vesting.release();

        assertEq(token.balanceOf(beneficiary), LOCKED / 24);
        assertEq(token.balanceOf(stranger), 0);
    }

    function test_ReleaseOnlyPaysOutNewlyUnlockedAmount() public {
        _warpToMonth(18);
        vesting.release();
        uint256 firstClaim = token.balanceOf(beneficiary);
        assertEq(firstClaim, (LOCKED * 6) / 24);

        // 同一时间点重复调用不会重复释放
        vesting.release();
        assertEq(token.balanceOf(beneficiary), firstClaim);

        // 再等 3 个月，只能多领 3/24
        _warpToMonth(21);
        assertEq(vesting.releasableToken(), (LOCKED * 3) / 24);
        vesting.release();
        assertEq(token.balanceOf(beneficiary), (LOCKED * 9) / 24);
    }

    function test_ReleaseAtMonth36UnlocksEverythingIncludingDust() public {
        _warpToMonth(12);
        vesting.release(); // Cliff 结束，释放 0

        vm.warp(DEPLOY_TIME + TOTAL);
        assertEq(vesting.releasableToken(), LOCKED, "all tokens should be releasable");

        vesting.release();
        assertEq(token.balanceOf(beneficiary), LOCKED, "rounding dust goes to beneficiary");
        assertEq(token.balanceOf(address(vesting)), 0);
    }

    function test_StaysFullyUnlockedAfterEnd() public {
        vm.warp(DEPLOY_TIME + 5 * 365 days);

        assertEq(vesting.vestedTokenAmount(_now()), LOCKED);

        vesting.release();
        assertEq(token.balanceOf(beneficiary), LOCKED);
    }

    function test_LateTransferFollowsTheSameSchedule() public {
        _warpToMonth(18); // 已释放 6/24 = 25%

        uint256 extra = 24_000e18;
        assertTrue(token.transfer(address(vesting), extra));

        // 与 OpenZeppelin VestingWallet 一致：转入的代币按同一时间表计算，因此 25% 立即可领
        assertEq(vesting.releasableToken(), (LOCKED + extra) * 6 / 24);
    }

    function testFuzz_VestedAmountFollowsLinearSchedule(uint64 elapsed) public {
        elapsed = elapsed % (TOTAL + 1); // 归一到 [0, 36 个月]
        vm.warp(DEPLOY_TIME + elapsed);

        uint256 expected;
        if (elapsed < CLIFF) {
            expected = 0;
        } else if (elapsed >= TOTAL) {
            expected = LOCKED;
        } else {
            expected = (LOCKED * (elapsed - CLIFF)) / LINEAR;
        }

        assertEq(vesting.vestedTokenAmount(_now()), expected);
    }

    // ---------------------------------------------------------------------
    // 其他约束
    // ---------------------------------------------------------------------

    function test_ReceiveEtherReverts() public {
        vm.deal(address(this), 1 ether);

        // 本合约只锁定 ERC20，直接发送 ETH 会被拒绝（避免 ETH 永久卡在合约里）
        (bool success, ) = payable(address(vesting)).call{value: 1 ether}("");
        assertFalse(success, "sending ether should revert");
        assertEq(address(vesting).balance, 0);
    }

    function test_OtherTokensAreNotReleasable() public {
        MockERC20 otherToken = new MockERC20();
        assertTrue(otherToken.transfer(address(vesting), 1_000e18));

        _warpToMonth(18);
        vesting.release();

        // release() 只会释放配置的锁定代币
        assertEq(token.balanceOf(beneficiary), (LOCKED * 6) / 24);
        assertEq(otherToken.balanceOf(address(vesting)), 1_000e18);
    }
}
