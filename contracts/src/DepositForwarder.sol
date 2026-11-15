// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/tron-contracts/proxy/Clones.sol";
import {IPaymasterFactory} from "./interfaces/IPaymasterFactory.sol";
import {ITRC20} from "./interfaces/ITRC20.sol";
import {TokenTransfer} from "./libraries/TokenTransfer.sol";

/// @title DepositForwarder
/// @notice A per-deposit address whose funds can only ever reach one treasury.
/// @dev Runs behind an ImplementationRouter clone with immutable args
/// `treasury ‖ sweeper` (40 bytes). The args are part of the CREATE2 init code
/// and therefore part of the address, so the destination is fixed before
/// anyone deposits. Holds no storage, so implementations can be swapped
/// through the factory timelock without migration.
///
/// With `sweeper == address(0)`, anyone may trigger a sweep and gains nothing by
/// doing so: the funds still land in the treasury. A non-zero `sweeper`
/// restricts who may trigger (for custodians that screen deposits before they
/// reach the treasury) without changing where funds can go.
///
/// The forwarder holds no state and emits no events: a TRC-20 sweep is already
/// visible as the token's own Transfer log.
contract DepositForwarder {
    error NotAuthorized();
    error DirectCallForbidden();

    address public immutable FACTORY;

    /// @notice Which implementation slot this contract is valid for; checked by
    /// `queueUpgrade` so a forwarder implementation can never be queued as an account (or vice versa).
    IPaymasterFactory.Kind public constant KIND = IPaymasterFactory.Kind.Forwarder;
    address private immutable SELF;

    constructor(address factory) {
        FACTORY = factory;
        SELF = address(this);
    }

    /// @dev Accepts TRX on clones. Best effort on the implementation itself:
    /// plain TRX transfers on Tron reach contracts without executing code.
    receive() external payable {
        if (address(this) == SELF) revert DirectCallForbidden();
    }

    function treasury() external view returns (address t) {
        (t,) = _args();
    }

    function sweeper() external view returns (address s) {
        (, s) = _args();
    }

    /// @notice Moves the full `token` balance to the treasury.
    function sweep(address token) external returns (uint256 amount) {
        address t = _authorize();
        amount = ITRC20(token).balanceOf(address(this));
        if (amount != 0) TokenTransfer.send(token, t, amount);
    }

    /// @notice Moves the full TRX balance to the treasury.
    function sweepTRX() external returns (uint256 amount) {
        address t = _authorize();
        amount = address(this).balance;
        if (amount != 0) {
            (bool ok,) = payable(t).call{value: amount}("");
            if (!ok) revert TokenTransfer.TransferFailed();
        }
    }

    function _authorize() private view returns (address t) {
        address s;
        (t, s) = _args();
        if (s != address(0) && msg.sender != s && msg.sender != FACTORY) revert NotAuthorized();
        if (IPaymasterFactory(FACTORY).paused()) revert IPaymasterFactory.ProtocolPaused();
    }

    function _args() private view returns (address t, address s) {
        if (address(this) == SELF) revert DirectCallForbidden();
        bytes memory a = Clones.fetchCloneArgs(address(this));
        assembly ("memory-safe") {
            t := shr(96, mload(add(a, 0x20)))
            s := shr(96, mload(add(a, 0x34)))
        }
    }
}
