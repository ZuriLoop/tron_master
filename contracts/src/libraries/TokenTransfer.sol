// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {ITRC20} from "../interfaces/ITRC20.sol";

/// @title TokenTransfer
/// @notice Sends TRC-20 tokens and proves the transfer happened.
/// @dev Neither SafeERC20 nor a void-returning interface is correct on Tron:
///  - Tron USDT's `transfer` returns `false` on success, so SafeERC20 reverts.
///  - Ignoring the return value alone accepts tokens that fail silently and
///    return `false`, which would let a permit consume its nonce and fees
///    without moving funds.
/// So the call must succeed, its return value is ignored, and the sender's
/// balance must fall by at least `amount`.
library TokenTransfer {
    error TransferFailed();

    /// @return remaining The sender's balance after the transfer, so callers
    /// can run post-checks without another balanceOf call.
    function send(address token, address to, uint256 amount) internal returns (uint256 remaining) {
        uint256 before = ITRC20(token).balanceOf(address(this));
        (bool ok,) = token.call(abi.encodeCall(ITRC20.transfer, (to, amount)));
        if (!ok) revert TransferFailed();
        remaining = ITRC20(token).balanceOf(address(this));
        if (remaining > before || before - remaining < amount) revert TransferFailed();
    }
}
