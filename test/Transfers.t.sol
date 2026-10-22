// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TripFund} from "../src/TripFund.sol";
import {TripFundV2} from "../src/TripFundV2.sol";

contract ControlledToken is ERC20 {
    enum Failure {
        None,
        ReturnFalse,
        Revert
    }

    enum Observation {
        None,
        Contribution,
        Refund,
        Withdraw
    }

    Failure public failure;
    Observation public observation;
    TripFund public fund;
    address public beneficiary;
    uint256 public expectedTotal;
    uint256 public expectedContribution;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    bool public attemptReentry;

    error TransferBlocked();

    constructor() ERC20("Controlled Token", "CTRL") {
        _mint(msg.sender, 10_000 ether);
    }

    function setFailure(Failure value) external {
        failure = value;
    }

    function observe(
        TripFund fund_,
        Observation observation_,
        address beneficiary_,
        uint256 total_,
        uint256 contribution_,
        bool reenter_
    ) external {
        fund = fund_;
        observation = observation_;
        beneficiary = beneficiary_;
        expectedTotal = total_;
        expectedContribution = contribution_;
        attemptReentry = reenter_;
    }

    function _checkStateAndReenter() internal {
        if (observation == Observation.None) return;
        require(fund.totalRaised() == expectedTotal, "total not updated before token call");
        require(
            fund.contributions(beneficiary) == expectedContribution,
            "contribution not updated before token call"
        );
        if (observation == Observation.Withdraw) {
            require(fund.withdrawn(), "withdrawn not set before token call");
        }
        if (attemptReentry) {
            callbackAttempted = true;
            bytes memory data;
            bytes memory callData = observation == Observation.Contribution
                ? abi.encodeCall(TripFund.contribute, (1))
                : observation == Observation.Refund
                    ? abi.encodeCall(TripFund.refund, ())
                    : abi.encodeCall(TripFund.withdraw, ());
            (callbackSucceeded, data) = address(fund).call(callData);
            if (data.length >= 4) callbackError = bytes4(data);
        }
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        _checkStateAndReenter();
        if (failure == Failure.ReturnFalse) return false;
        if (failure == Failure.Revert) revert TransferBlocked();
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        _checkStateAndReenter();
        if (failure == Failure.ReturnFalse) return false;
        if (failure == Failure.Revert) revert TransferBlocked();
        return super.transferFrom(from, to, amount);
    }
}

abstract contract TransferBehavior is Test {
    address internal constant ALICE = address(0xA11CE);
    address internal constant ORGANIZER = address(0xC0FFEE);
    ControlledToken internal token;
    TripFund internal fund;
    uint256 internal end;

    function _implementation() internal virtual returns (address);

    function setUp() public {
        vm.warp(1_800_000_000);
        end = block.timestamp + 7 days;
        token = new ControlledToken();
        assertTrue(token.transfer(ALICE, 1_000 ether));
        fund = TripFund(
            address(
                new TransparentUpgradeableProxy(
                    _implementation(),
                    address(0xAD),
                    abi.encodeCall(TripFund.initialize, (address(token), ORGANIZER, 100 ether, end))
                )
            )
        );
        vm.prank(ALICE);
        assertTrue(token.approve(address(fund), 1_000 ether));
    }

    function _expectTransferFailure(bool returnFalse) internal {
        token.setFailure(
            returnFalse ? ControlledToken.Failure.ReturnFalse : ControlledToken.Failure.Revert
        );
        if (returnFalse) {
            vm.expectRevert(
                abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token))
            );
        } else {
            vm.expectRevert(ControlledToken.TransferBlocked.selector);
        }
    }

    function testFuzzFailedIncomingTransferRollsBack(bool returnFalse) public {
        _expectTransferFailure(returnFalse);
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(fund.totalRaised(), 0);
        assertEq(fund.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(token.allowance(ALICE, address(fund)), 1_000 ether);
        token.setFailure(ControlledToken.Failure.None);
        vm.prank(ALICE);
        fund.contribute(10 ether);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testFuzzFailedRefundRestoresContributionAndCanRetry(bool returnFalse) public {
        vm.prank(ALICE);
        fund.contribute(10 ether);
        vm.warp(end);
        _expectTransferFailure(returnFalse);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 10 ether);
        assertEq(fund.totalRaised(), 10 ether);
        assertEq(token.balanceOf(ALICE), 990 ether);
        assertEq(token.balanceOf(address(fund)), 10 ether);
        token.setFailure(ControlledToken.Failure.None);
        vm.prank(ALICE);
        fund.refund();
        assertEq(fund.contributions(ALICE), 0);
        assertEq(token.balanceOf(ALICE), 1_000 ether);
        assertEq(token.balanceOf(address(fund)), 0);
        assertEq(fund.totalRaised(), 10 ether);
    }

    function testFuzzFailedWithdrawRestoresFlagAndCanRetry(bool returnFalse) public {
        vm.prank(ALICE);
        fund.contribute(100 ether);
        vm.warp(end);
        _expectTransferFailure(returnFalse);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertFalse(fund.withdrawn());
        assertEq(fund.totalRaised(), 100 ether);
        assertEq(fund.contributions(ALICE), 100 ether);
        assertEq(token.balanceOf(address(fund)), 100 ether);
        assertEq(token.balanceOf(ORGANIZER), 0);
        token.setFailure(ControlledToken.Failure.None);
        vm.prank(ORGANIZER);
        fund.withdraw();
        assertTrue(fund.withdrawn());
        assertEq(token.balanceOf(ORGANIZER), 100 ether);
        assertEq(token.balanceOf(address(fund)), 0);
    }

    function testContributionUpdatesStateBeforeExternalCallAndBlocksReentry() public {
        token.observe(
            fund, ControlledToken.Observation.Contribution, ALICE, 10 ether, 10 ether, true
        );
        vm.prank(ALICE);
        fund.contribute(10 ether);
        _assertReentryBlocked();
        assertEq(fund.totalRaised(), 10 ether);
        assertEq(token.balanceOf(address(fund)), 10 ether);
    }

    function testRefundClearsContributionBeforeExternalCallAndBlocksReentry() public {
        vm.prank(ALICE);
        fund.contribute(10 ether);
        vm.warp(end);
        token.observe(fund, ControlledToken.Observation.Refund, ALICE, 10 ether, 0, true);
        vm.prank(ALICE);
        fund.refund();
        _assertReentryBlocked();
        assertEq(token.balanceOf(ALICE), 1_000 ether);
    }

    function testWithdrawSetsFlagBeforeExternalCallAndBlocksReentry() public {
        vm.prank(ALICE);
        fund.contribute(100 ether);
        vm.warp(end);
        token.observe(fund, ControlledToken.Observation.Withdraw, ALICE, 100 ether, 100 ether, true);
        vm.prank(ORGANIZER);
        fund.withdraw();
        _assertReentryBlocked();
        assertEq(token.balanceOf(ORGANIZER), 100 ether);
    }

    function _assertReentryBlocked() internal view {
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(
            token.callbackError(), ReentrancyGuardUpgradeable.ReentrancyGuardReentrantCall.selector
        );
    }
}

contract TransfersV1Test is TransferBehavior {
    function _implementation() internal override returns (address) {
        return address(new TripFund());
    }
}

contract TransfersV2Test is TransferBehavior {
    function _implementation() internal override returns (address) {
        return address(new TripFundV2());
    }
}
