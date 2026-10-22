// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockToken} from "../src/MockToken.sol";

abstract contract TripFundBehavior is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ORGANIZER = address(0xC0FFEE);
    address internal constant ADMIN_OWNER = address(0xAD);
    uint256 internal constant GOAL = 100 ether;
    uint256 internal constant INITIAL_BALANCE = 1_000 ether;
    uint256 internal end;
    address internal implementation;
    MockToken internal token;
    TripFund internal fund;

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refunded(address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    function _implementation() internal virtual returns (address);

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        token = new MockToken(1_000_000 ether);
        assertTrue(token.transfer(ALICE, INITIAL_BALANCE));
        assertTrue(token.transfer(BOB, INITIAL_BALANCE));
        implementation = _implementation();
        fund = _deploy(address(token), ORGANIZER, GOAL, end);
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), type(uint256).max));
        vm.prank(BOB);
        assertTrue(token.approve(address(fund), type(uint256).max));
    }

    function _deploy(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        returns (TripFund)
    {
        return TripFund(
            address(
                new TransparentUpgradeableProxy(
                    implementation,
                    ADMIN_OWNER,
                    abi.encodeCall(TripFund.initialize, (token_, organizer_, goal_, deadline_))
                )
            )
        );
    }

    function _contribute(address payer, uint256 amount) internal {
        vm.prank(payer);
        fund.contribute(amount);
    }

    function _assertUntouched() internal view {
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 0);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertFalse(fund.withdrawn());
    }

    function testInitialParametersAndEmptyAccounting() public view {
        assertEq(address(fund.token()), address(token));
        assertEq(fund.organizer(), ORGANIZER);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), end);
        _assertUntouched();
    }

    function testRejectZeroToken() public {
        vm.expectRevert(TripFund.ZeroAddress.selector);
        _deploy(address(0), ORGANIZER, GOAL, end);
    }

    function testRejectZeroOrganizer() public {
        vm.expectRevert(TripFund.ZeroAddress.selector);
        _deploy(address(token), address(0), GOAL, end);
    }

    function testRejectZeroGoal() public {
        vm.expectRevert(TripFund.ZeroGoal.selector);
        _deploy(address(token), ORGANIZER, 0, end);
    }

    function testRejectDeadlineNow() public {
        vm.expectRevert(TripFund.InvalidDeadline.selector);
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp);
    }

    function testRejectPastDeadline() public {
        vm.expectRevert(TripFund.InvalidDeadline.selector);
        _deploy(address(token), ORGANIZER, GOAL, block.timestamp - 1);
    }

    function testAcceptDeadlineOneSecondInFuture() public {
        TripFund other = _deploy(address(token), ORGANIZER, 1, block.timestamp + 1);
        assertEq(other.deadline(), block.timestamp + 1);
    }

    function testCannotInitializeImplementationDirectly() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        TripFund(implementation).initialize(address(token), ORGANIZER, GOAL, end);
    }

    function testCannotReinitializeProxy() public {
        vm.prank(ALICE);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fund.initialize(address(token), ALICE, 1, end + 1);
        assertEq(fund.organizer(), ORGANIZER);
        assertEq(fund.goal(), GOAL);
        assertEq(fund.deadline(), end);
        assertEq(address(fund.token()), address(token));
    }

    function testTwoParticipantsAndRepeatedContributions() public {
        _contribute(ALICE, 20 ether);
        _contribute(BOB, 30 ether);
        _contribute(ALICE, 15 ether);
        assertEq(fund.contributions(ALICE), 35 ether);
        assertEq(fund.contributions(BOB), 30 ether);
        assertEq(fund.totalRaised(), 65 ether);
        assertEq(token.balanceOf(address(fund)), 65 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 35 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 30 ether);
    }

    function testContributionEvent() public {
        vm.expectEmit(true, true, false, true, address(fund));
        emit Contributed(ALICE, ALICE, 10 ether);
        _contribute(ALICE, 10 ether);
    }

    function testZeroContributionRollsBack() public {
        vm.prank(ALICE);
        vm.expectRevert(TripFund.ZeroAmount.selector);
        fund.contribute(0);
        _assertUntouched();
    }

    function testInsufficientBalanceRollsBack() public {
        uint256 amount = INITIAL_BALANCE + 1;
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, INITIAL_BALANCE, amount
            )
        );
        fund.contribute(amount);
        _assertUntouched();
        assertEq(token.allowance(ALICE, address(fund)), type(uint256).max);
    }

    function testInsufficientAllowanceRollsBack() public {
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), 4 ether));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 4 ether, 5 ether
            )
        );
        fund.contribute(5 ether);
        _assertUntouched();
        assertEq(token.allowance(ALICE, address(fund)), 4 ether);
    }

    function testMissingApprovalRollsBack() public {
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), 0));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(fund), 0, 1
            )
        );
        fund.contribute(1);
        _assertUntouched();
    }

    function testRepeatedContributionFailurePreservesPreviousAccounting() public {
        _contribute(ALICE, 10 ether);
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), 0));
        vm.prank(ALICE);
        vm.expectRevert();
        fund.contribute(1 ether);
        assertEq(fund.totalRaised(), 10 ether);
        assertEq(fund.contributions(ALICE), 10 ether);
        assertEq(token.balanceOf(address(fund)), 10 ether);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE - 10 ether);
    }

    function testFiniteAllowanceIsSpent() public {
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), 10 ether));
        _contribute(ALICE, 6 ether);
        assertEq(token.allowance(ALICE, address(fund)), 4 ether);
    }

    function testContributionOneSecondBeforeDeadline() public {
        vm.warp(end - 1);
        _contribute(ALICE, 1);
        assertEq(fund.totalRaised(), 1);
        assertEq(token.balanceOf(address(fund)), 1);
    }

    function testContributionAtDeadlineRejected() public {
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.FundClosed.selector);
        fund.contribute(1);
        _assertUntouched();
    }

    function testContributionAfterDeadlineRejected() public {
        vm.warp(end + 1);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.FundClosed.selector);
        fund.contribute(1);
        _assertUntouched();
    }

    function testNoEarlyWithdrawEvenWhenGoalReached() public {
        _contribute(ALICE, GOAL);
        vm.warp(end - 1);
        vm.prank(ORGANIZER);
        vm.expectRevert(TripFund.FundStillOpen.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
    }

    function testNoEarlyRefund() public {
        _contribute(ALICE, 10 ether);
        vm.warp(end - 1);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.FundStillOpen.selector);
        fund.refund();
        assertEq(fund.contributions(ALICE), 10 ether);
        assertEq(token.balanceOf(address(fund)), 10 ether);
    }

    function testWithdrawExactlyGoalAtDeadline() public {
        _contribute(ALICE, 40 ether);
        _contribute(BOB, 60 ether);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Withdrawn(ORGANIZER, GOAL);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(token.balanceOf(address(fund)), 0);
        assertTrue(fund.withdrawn());
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(ALICE), 40 ether);
        assertEq(fund.contributions(BOB), 60 ether);
    }

    function testWithdrawAboveGoalPaysWholeAccountedAmount() public {
        _contribute(ALICE, 70 ether);
        _contribute(BOB, 80 ether);
        vm.warp(end + 1);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), 150 ether);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 150 ether);
    }

    function testStrangerCannotWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.prank(BOB);
        vm.expectRevert(TripFund.NotOrganizer.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
    }

    function testCannotWithdrawTwice() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.startPrank(ORGANIZER);
        fund.withdraw();
        vm.expectRevert(TripFund.AlreadyWithdrawn.selector);
        fund.withdraw();
        vm.stopPrank();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testCannotWithdrawFailedFund() public {
        _contribute(ALICE, GOAL - 1);
        vm.warp(end);
        vm.prank(ORGANIZER);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), 0);
        assertEq(token.balanceOf(address(fund)), GOAL - 1);
    }

    function testIndependentFullRefundsAtDeadline() public {
        _contribute(ALICE, 10 ether);
        _contribute(BOB, 30 ether);
        _contribute(ALICE, 15 ether);
        vm.warp(end);
        vm.expectEmit(true, false, false, true, address(fund));
        emit Refunded(ALICE, 25 ether);
        vm.prank(ALICE);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 30 ether);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE - 30 ether);
        assertEq(token.balanceOf(address(fund)), 30 ether);
        assertEq(fund.totalRaised(), 55 ether);
        vm.prank(BOB);
        fund.refund();
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(fund.contributions(BOB), 0);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 55 ether);
    }

    function testRefundWithoutContributionRejected() public {
        _contribute(ALICE, 1);
        vm.warp(end);
        vm.prank(BOB);
        vm.expectRevert(TripFund.NoContribution.selector);
        fund.refund();
        assertEq(fund.contributions(ALICE), 1);
        assertEq(token.balanceOf(address(fund)), 1);
    }

    function testRefundTwiceRejected() public {
        _contribute(ALICE, 10 ether);
        vm.warp(end);
        vm.startPrank(ALICE);
        fund.refund();
        vm.expectRevert(TripFund.NoContribution.selector);
        fund.refund();
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testRefundSuccessfulFundRejectedBeforeAndAfterWithdraw() public {
        _contribute(ALICE, GOAL);
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.GoalReached.selector);
        fund.refund();
        vm.prank(ORGANIZER);
        fund.withdraw();
        vm.prank(ALICE);
        vm.expectRevert(TripFund.GoalReached.selector);
        fund.refund();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(fund.contributions(ALICE), GOAL);
    }

    function testEmptyFundHasNoPayouts() public {
        vm.warp(end);
        vm.prank(ORGANIZER);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(ALICE);
        vm.expectRevert(TripFund.NoContribution.selector);
        fund.refund();
        _assertUntouched();
    }

    function testDirectTransferStaysAfterSuccessfulWithdraw() public {
        _contribute(ALICE, GOAL);
        assertTrue(token.transfer(address(fund), 7 ether));
        assertEq(fund.totalRaised(), GOAL);
        assertEq(fund.contributions(address(this)), 0);
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), GOAL);
        assertEq(token.balanceOf(address(fund)), 7 ether);
        assertEq(fund.totalRaised(), GOAL);
    }

    function testDirectTransferCannotMakeFundSuccessfulAndStaysAfterRefunds() public {
        assertTrue(token.transfer(address(fund), GOAL));
        _contribute(ALICE, 20 ether);
        _contribute(BOB, 30 ether);
        assertEq(fund.totalRaised(), 50 ether);
        assertEq(fund.contributions(address(this)), 0);
        vm.warp(end);
        vm.prank(ORGANIZER);
        vm.expectRevert(TripFund.GoalNotReached.selector);
        fund.withdraw();
        vm.prank(ALICE);
        fund.refund();
        vm.prank(BOB);
        fund.refund();
        assertEq(token.balanceOf(address(fund)), GOAL);
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(fund.totalRaised(), 50 ether);
    }

    function testFuzzSuccessfulWithdraw(uint96 a, uint96 b, uint96 extra) public {
        uint256 amountA = bound(uint256(a), 1, INITIAL_BALANCE);
        uint256 amountB = bound(uint256(b), 1, INITIAL_BALANCE);
        uint256 donation = bound(uint256(extra), 0, 100 ether);
        fund = _deploy(address(token), ORGANIZER, amountA + amountB, end);
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), amountA));
        vm.prank(BOB);
        assertTrue(token.approve(address(fund), amountB));
        _contribute(ALICE, amountA);
        _contribute(BOB, amountB);
        assertTrue(token.transfer(address(fund), donation));
        vm.warp(end);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertEq(token.balanceOf(ORGANIZER), amountA + amountB);
        assertEq(token.balanceOf(address(fund)), donation);
        assertEq(fund.totalRaised(), amountA + amountB);
    }

    function testFuzzFailedFundRefunds(uint96 a, uint96 b, bool bobFirst) public {
        uint256 amountA = bound(uint256(a), 1, INITIAL_BALANCE);
        uint256 amountB = bound(uint256(b), 1, INITIAL_BALANCE);
        fund = _deploy(address(token), ORGANIZER, amountA + amountB + 1, end);
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), amountA));
        vm.prank(BOB);
        assertTrue(token.approve(address(fund), amountB));
        _contribute(ALICE, amountA);
        _contribute(BOB, amountB);
        vm.warp(end);
        vm.prank(bobFirst ? BOB : ALICE);
        fund.refund();
        vm.prank(bobFirst ? ALICE : BOB);
        fund.refund();
        assertEq(token.balanceOf(ALICE), INITIAL_BALANCE);
        assertEq(token.balanceOf(BOB), INITIAL_BALANCE);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), amountA + amountB);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(fund.contributions(BOB), 0);
    }
}

contract TripFundV1Test is TripFundBehavior {
    function _implementation() internal override returns (address) {
        return address(new TripFund());
    }
}

contract TripFundV2BehaviorTest is TripFundBehavior {
    function _implementation() internal override returns (address) {
        return address(new TripFundV2());
    }
}
