// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

/// @notice The two TRC-20 functions TronPaymaster calls. `transfer` is never
/// relied on for its return value: Tron USDT returns `false` on success.
interface ITRC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 value) external returns (bool);
}
