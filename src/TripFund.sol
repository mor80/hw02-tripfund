// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    ReentrancyGuardUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";

contract TripFund is Initializable, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public token;
    address public organizer;
    uint256 public goal;
    uint256 public deadline;
    mapping(address => uint256) public contributions;
    uint256 public totalRaised;
    bool public withdrawn;

    error ZeroAddress();
    error ZeroGoal();
    error InvalidDeadline();
    error ZeroAmount();
    error FundClosed();
    error FundStillOpen();
    error NotOrganizer();
    error GoalNotReached();
    error GoalReached();
    error AlreadyWithdrawn();
    error NoContribution();

    event Contributed(address indexed payer, address indexed beneficiary, uint256 amount);
    event Refunded(address indexed beneficiary, uint256 amount);
    event Withdrawn(address indexed organizer, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        public
        virtual
        initializer
    {
        __TripFund_init(token_, organizer_, goal_, deadline_);
    }

    function __TripFund_init(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        internal
        onlyInitializing
    {
        if (token_ == address(0) || organizer_ == address(0)) revert ZeroAddress();
        if (goal_ == 0) revert ZeroGoal();
        if (deadline_ <= block.timestamp) revert InvalidDeadline();

        __ReentrancyGuard_init();
        token = IERC20(token_);
        organizer = organizer_;
        goal = goal_;
        deadline = deadline_;
    }

    function contribute(uint256 amount) external nonReentrant {
        _contribute(msg.sender, msg.sender, amount);
    }

    function withdraw() external nonReentrant {
        if (block.timestamp < deadline) revert FundStillOpen();
        if (msg.sender != organizer) revert NotOrganizer();
        if (totalRaised < goal) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();

        withdrawn = true;
        uint256 amount = totalRaised;
        token.safeTransfer(organizer, amount);
        emit Withdrawn(organizer, amount);
    }

    function refund() external nonReentrant {
        if (block.timestamp < deadline) revert FundStillOpen();
        if (totalRaised >= goal) revert GoalReached();
        uint256 amount = contributions[msg.sender];
        if (amount == 0) revert NoContribution();

        contributions[msg.sender] = 0;
        token.safeTransfer(msg.sender, amount);
        emit Refunded(msg.sender, amount);
    }

    function _contribute(address payer, address beneficiary, uint256 amount) internal {
        if (block.timestamp >= deadline) revert FundClosed();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        contributions[beneficiary] += amount;
        totalRaised += amount;
        token.safeTransferFrom(payer, address(this), amount);
        emit Contributed(payer, beneficiary, amount);
    }
}
