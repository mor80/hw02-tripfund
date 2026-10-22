// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TripFund} from "./TripFund.sol";

/// @custom:oz-upgrades-from src/TripFund.sol:TripFund
contract TripFundV2 is TripFund {
    function initialize(address token_, address organizer_, uint256 goal_, uint256 deadline_)
        public
        override
        initializer
    {
        __TripFund_init(token_, organizer_, goal_, deadline_);
    }

    function contributeFor(address beneficiary, uint256 amount) external nonReentrant {
        _contribute(msg.sender, beneficiary, amount);
    }
}
