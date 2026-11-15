// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {IPaymasterFactory} from "./interfaces/IPaymasterFactory.sol";

/// @title ImplementationRouter
/// @notice The fixed delegate target of every forwarder or account clone.
/// @dev Clones are EIP-1167 proxies with immutable args whose target is this
/// router, so a clone's CREATE2 address never depends on the implementation.
/// The router itself is immutable: on each call it asks the factory for the
/// current implementation of its `KIND` and delegatecalls it. Upgrades
/// therefore happen only through the factory's timelock.
///
/// Inside the delegatecall `address(this)` is still the clone, so the
/// implementation reads its immutable args from the clone's own code.
contract ImplementationRouter {
    error DirectCallForbidden();

    address public immutable FACTORY;
    IPaymasterFactory.Kind public immutable KIND;
    address private immutable SELF;

    constructor(address factory, IPaymasterFactory.Kind kind) {
        FACTORY = factory;
        KIND = kind;
        SELF = address(this);
    }

    fallback() external payable {
        _route();
    }

    receive() external payable {
        _route();
    }

    function _route() private {
        if (address(this) == SELF) revert DirectCallForbidden();
        address impl = IPaymasterFactory(FACTORY).implementation(KIND);
        // Not memory-safe (copies calldata over scratch and beyond), but never
        // returns to Solidity code.
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(ok) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}
