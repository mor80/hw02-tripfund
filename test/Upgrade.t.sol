// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    TransparentUpgradeableProxy,
    ITransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";
import {MockToken} from "../src/MockToken.sol";

contract UpgradeTest is Test {
    bytes32 internal constant ADMIN_SLOT =
        0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant ORGANIZER = address(0xC0FFEE);
    address internal constant ADMIN_OWNER = address(0xAD);
    uint256 internal end;
    MockToken internal token;
    TripFund internal v1;
    TripFundV2 internal v2;
    ProxyAdmin internal admin;
    TripFundV2 internal next;
    address internal oldImplementation;

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        token = new MockToken(10_000 ether);
        assertTrue(token.transfer(ALICE, 1_000 ether));
        assertTrue(token.transfer(BOB, 1_000 ether));
        oldImplementation = address(new TripFund());
        v1 = TripFund(
            address(
                new TransparentUpgradeableProxy(
                    oldImplementation,
                    ADMIN_OWNER,
                    abi.encodeCall(TripFund.initialize, (address(token), ORGANIZER, 100 ether, end))
                )
            )
        );
        admin = ProxyAdmin(address(uint160(uint256(vm.load(address(v1), ADMIN_SLOT)))));
        next = new TripFundV2();
        vm.prank(ALICE);
        assertTrue(token.approve(address(v1), type(uint256).max));
        vm.prank(BOB);
        assertTrue(token.approve(address(v1), type(uint256).max));
    }

    function _upgrade() internal {
        vm.prank(ADMIN_OWNER);
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(next), "");
        v2 = TripFundV2(address(v1));
    }

    function testUpgradePreservesStateThenFriendGetsRefund() public {
        vm.prank(ALICE);
        v1.contribute(20 ether);
        assertTrue(token.transfer(address(v1), 7 ether));
        address proxy = address(v1);
        vm.warp(end - 100);
        assertLt(block.timestamp, end);
        assertEq(admin.owner(), ADMIN_OWNER);
        _upgrade();

        assertEq(address(v2), proxy);
        assertEq(address(v2.token()), address(token));
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), 100 ether);
        assertEq(v2.deadline(), end);
        assertEq(v2.contributions(ALICE), 20 ether);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.totalRaised(), 20 ether);
        assertEq(token.balanceOf(proxy), 27 ether);
        assertFalse(v2.withdrawn());
        assertEq(token.allowance(ALICE, proxy), type(uint256).max);
        assertEq(address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT)))), address(next));
        assertEq(address(uint160(uint256(vm.load(proxy, ADMIN_SLOT)))), address(admin));

        vm.prank(ALICE);
        v2.contributeFor(BOB, 30 ether);
        vm.prank(ALICE);
        v2.contribute(5 ether);
        assertEq(v2.contributions(ALICE), 25 ether);
        assertEq(v2.contributions(BOB), 30 ether);
        assertEq(v2.totalRaised(), 55 ether);
        assertEq(token.balanceOf(proxy), 62 ether);
        assertEq(token.balanceOf(ALICE), 945 ether);
        assertEq(token.balanceOf(BOB), 1_000 ether);

        vm.warp(end);
        vm.prank(BOB);
        v2.refund();
        assertEq(token.balanceOf(BOB), 1_030 ether);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.contributions(ALICE), 25 ether);
        vm.prank(ALICE);
        v2.refund();
        assertEq(token.balanceOf(ALICE), 970 ether);
        assertEq(token.balanceOf(proxy), 7 ether);
        assertEq(v2.totalRaised(), 55 ether);
    }

    function testOnlyProxyAdminOwnerCanUpgrade() public {
        vm.prank(ORGANIZER);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ORGANIZER)
        );
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(next), "");
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        admin.upgradeAndCall(ITransparentUpgradeableProxy(address(v1)), address(next), "");
        assertEq(
            address(uint160(uint256(vm.load(address(v1), IMPLEMENTATION_SLOT)))), oldImplementation
        );
        _upgrade();
        assertEq(
            address(uint160(uint256(vm.load(address(v1), IMPLEMENTATION_SLOT)))), address(next)
        );
    }

    function testCallingProxyUpgradeDirectlyCannotBypassAdmin() public {
        vm.prank(ADMIN_OWNER);
        vm.expectRevert();
        ITransparentUpgradeableProxy(address(v1)).upgradeToAndCall(address(next), "");
        assertEq(
            address(uint160(uint256(vm.load(address(v1), IMPLEMENTATION_SLOT)))), oldImplementation
        );
    }

    function testCannotReinitializeAfterUpgrade() public {
        _upgrade();
        vm.prank(ALICE);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        v2.initialize(address(token), ALICE, 1, end + 1);
        assertEq(v2.organizer(), ORGANIZER);
        assertEq(v2.goal(), 100 ether);
        assertEq(v2.deadline(), end);
    }

    function testCannotInitializeV2Implementation() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        next.initialize(address(token), ORGANIZER, 100 ether, end);
    }

    function testUpgradeAndReinitializeAtomicallyReverts() public {
        vm.prank(ADMIN_OWNER);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        admin.upgradeAndCall(
            ITransparentUpgradeableProxy(address(v1)),
            address(next),
            abi.encodeCall(TripFund.initialize, (address(token), ALICE, 1, end + 1))
        );
        assertEq(
            address(uint160(uint256(vm.load(address(v1), IMPLEMENTATION_SLOT)))), oldImplementation
        );
        assertEq(v1.organizer(), ORGANIZER);
    }

    function testSponsoredEventAndRepeatedContributions() public {
        _upgrade();
        vm.expectEmit(true, true, false, true, address(v2));
        emit Contributed(ALICE, BOB, 10 ether);
        vm.prank(ALICE);
        v2.contributeFor(BOB, 10 ether);
        vm.prank(ALICE);
        v2.contributeFor(BOB, 15 ether);
        vm.prank(BOB);
        v2.contribute(5 ether);
        assertEq(v2.contributions(BOB), 30 ether);
        assertEq(v2.contributions(ALICE), 0);
        assertEq(v2.totalRaised(), 30 ether);
        assertEq(token.balanceOf(ALICE), 975 ether);
        assertEq(token.balanceOf(BOB), 995 ether);
    }

    function testPayerCannotRefundGiftAndFriendCannotRefundTwice() public {
        _upgrade();
        vm.prank(ALICE);
        v2.contributeFor(BOB, 10 ether);
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.NoContribution.selector);
        v2.refund();
        vm.startPrank(BOB);
        v2.refund();
        vm.expectRevert(TripFund.NoContribution.selector);
        v2.refund();
        vm.stopPrank();
        assertEq(token.balanceOf(ALICE), 990 ether);
        assertEq(token.balanceOf(BOB), 1_010 ether);
        assertEq(v2.totalRaised(), 10 ether);
    }

    function testContributeForSelf() public {
        _upgrade();
        vm.prank(ALICE);
        v2.contributeFor(ALICE, 10 ether);
        assertEq(v2.contributions(ALICE), 10 ether);
        assertEq(v2.totalRaised(), 10 ether);
    }

    function testContributeForZeroBeneficiaryRejected() public {
        _upgrade();
        vm.prank(ALICE);
        vm.expectRevert(TripFund.ZeroAddress.selector);
        v2.contributeFor(address(0), 10 ether);
        _assertNoSponsoredContribution();
    }

    function testContributeForZeroAmountRejected() public {
        _upgrade();
        vm.prank(ALICE);
        vm.expectRevert(TripFund.ZeroAmount.selector);
        v2.contributeFor(BOB, 0);
        _assertNoSponsoredContribution();
    }

    function testContributeForNeedsPayerAllowanceEvenIfFriendApproved() public {
        _upgrade();
        vm.prank(ALICE);
        assertTrue(token.approve(address(v2), 0));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(v2), 0, 10 ether
            )
        );
        v2.contributeFor(BOB, 10 ether);
        _assertNoSponsoredContribution();
    }

    function testContributeForNeedsPayerBalanceEvenIfFriendHasFunds() public {
        _upgrade();
        vm.prank(ALICE);
        assertTrue(token.transfer(ORGANIZER, 1_000 ether));
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, ALICE, 0, 10 ether
            )
        );
        v2.contributeFor(BOB, 10 ether);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.totalRaised(), 0);
        assertEq(token.balanceOf(address(v2)), 0);
        assertEq(token.balanceOf(BOB), 1_000 ether);
    }

    function testFriendDoesNotNeedBalanceOrAllowance() public {
        _upgrade();
        address friend = address(0xF123);
        vm.prank(ALICE);
        v2.contributeFor(friend, 10 ether);
        vm.warp(end);
        vm.prank(friend);
        v2.refund();
        assertEq(token.balanceOf(friend), 10 ether);
        assertEq(token.balanceOf(ALICE), 990 ether);
    }

    function testContributeForDeadlineBoundaries() public {
        _upgrade();
        vm.warp(end - 1);
        vm.prank(ALICE);
        v2.contributeFor(BOB, 1);
        vm.warp(end);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.FundClosed.selector);
        v2.contributeFor(BOB, 1);
        vm.warp(end + 1);
        vm.prank(ALICE);
        vm.expectRevert(TripFund.FundClosed.selector);
        v2.contributeFor(BOB, 1);
        assertEq(v2.totalRaised(), 1);
        assertEq(v2.contributions(BOB), 1);
        assertEq(token.balanceOf(address(v2)), 1);
    }

    function testSponsoredSuccessPaysOrganizerAndBlocksFriendRefund() public {
        _upgrade();
        vm.prank(ALICE);
        v2.contributeFor(BOB, 100 ether);
        vm.prank(BOB);
        vm.expectRevert(TripFund.FundStillOpen.selector);
        v2.refund();
        vm.prank(ORGANIZER);
        vm.expectRevert(TripFund.FundStillOpen.selector);
        v2.withdraw();
        vm.warp(end);
        vm.prank(BOB);
        vm.expectRevert(TripFund.GoalReached.selector);
        v2.refund();
        vm.prank(ORGANIZER);
        v2.withdraw();
        assertEq(token.balanceOf(ORGANIZER), 100 ether);
        assertEq(v2.totalRaised(), 100 ether);
    }

    function testFuzzSponsoredRefund(address friend, uint96 value) public {
        vm.assume(friend != address(0) && friend != ALICE && friend != address(v1));
        vm.assume(friend != address(admin) && friend != address(token));
        uint256 amount = bound(uint256(value), 1, 99 ether);
        uint256 beforeBalance = token.balanceOf(friend);
        _upgrade();
        vm.prank(ALICE);
        v2.contributeFor(friend, amount);
        vm.warp(end);
        vm.prank(friend);
        v2.refund();
        assertEq(token.balanceOf(friend), beforeBalance + amount);
        assertEq(token.balanceOf(ALICE), 1_000 ether - amount);
        assertEq(v2.totalRaised(), amount);
        assertEq(v2.contributions(friend), 0);
    }

    function _assertNoSponsoredContribution() internal view {
        assertEq(v2.contributions(ALICE), 0);
        assertEq(v2.contributions(BOB), 0);
        assertEq(v2.totalRaised(), 0);
        assertEq(token.balanceOf(address(v2)), 0);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(BOB), 1_000 ether);
    }
}
