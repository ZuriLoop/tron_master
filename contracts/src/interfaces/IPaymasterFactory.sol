// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Permit} from "./IPermitAccount.sol";

/// @notice Deploys deposit forwarders and permit accounts, and governs the
/// implementation they run.
/// @dev Governance guarantees, all enforced on-chain:
///  - Upgrades wait at least `UPGRADE_DELAY` (immutable, >= 48h) after being
///    queued, and the guardian can veto them, so owners always have a window to
///    exit before new code applies to their account. A queued action that is
///    not executed within `EXECUTION_WINDOW` of its eta lapses.
///  - Role changes (admin, guardian) wait the same delay.
///  - A pause blocks permits and sweeps only. Owner withdrawals, signer
///    rotation and nonce invalidation are never pausable. Every pause expires
///    after `PAUSE_DURATION` (immutable), and the guardian has a cooldown
///    before it can pause again.
///  - The protocol fee is bounded by the immutable `MAX_BPS` / `MAX_CAP`, and
///    each permit's signed `maxFee` bounds what any single transfer pays.
interface IPaymasterFactory {
    enum Kind {
        Forwarder,
        Account
    }

    /// @notice One custodial sweep. `token == address(0)` sweeps TRX.
    struct SweepItem {
        address treasury;
        address sweeper;
        bytes32 salt;
        address token;
    }

    event ForwarderDeployed(address indexed forwarder, address indexed treasury, address sweeper, bytes32 salt);
    event AccountDeployed(address indexed account, address indexed owner, uint256 index);
    event ProtocolFeeUpdated(uint16 bps, uint128 cap);
    event UpgradeQueued(Kind indexed kind, address indexed implementation, uint256 eta);
    event UpgradeCancelled(Kind indexed kind, address indexed implementation, address by);
    event Upgraded(Kind indexed kind, address indexed implementation);
    event RolesQueued(address admin, address guardian, uint256 eta);
    event RolesCancelled();
    event RolesUpdated(address admin, address guardian);
    event Paused(address indexed by, uint256 until);
    event Unpaused(address indexed by);

    error InvalidTreasury();
    error InvalidConfig();
    error InvalidImplementation();
    error NotAuthorized();
    error NotAdmin();
    error FeeAboveMax();
    error PredictionMismatch();
    error NothingQueued();
    error TooEarly();
    error TooLate();
    error AlreadyPaused();
    error PauseCooldown();
    error ProtocolPaused();

    // immutable configuration
    function FEE_TOKEN() external view returns (address);
    function FEE_RECIPIENT() external view returns (address);
    function MAX_BPS() external view returns (uint16);
    function MAX_CAP() external view returns (uint128);
    function UPGRADE_DELAY() external view returns (uint256);
    function PAUSE_DURATION() external view returns (uint256);
    function FORWARDER_ROUTER() external view returns (address);
    function ACCOUNT_ROUTER() external view returns (address);

    // governance state
    function admin() external view returns (address);
    function guardian() external view returns (address);
    function implementation(Kind kind) external view returns (address);
    function pendingUpgrade(Kind kind) external view returns (address implementation, uint256 eta);
    function pendingRoles() external view returns (address admin, address guardian, uint256 eta);
    function pausedUntil() external view returns (uint64);
    function guardianPauseAvailableAt() external view returns (uint64);
    function paused() external view returns (bool);

    // governance actions
    function queueUpgrade(Kind kind, address newImplementation) external;
    function cancelUpgrade(Kind kind) external;
    function executeUpgrade(Kind kind) external;
    function queueRoles(address newAdmin, address newGuardian) external;
    function cancelRoles() external;
    function executeRoles() external;
    function pause() external;
    function unpause() external;
    function setProtocolFee(uint16 newBps, uint128 newCap) external;

    // fees
    function bps() external view returns (uint16);
    function cap() external view returns (uint128);
    function protocolFee(address token, uint256 value) external view returns (uint256);
    /// @notice `protocolFee`, reverting with `ProtocolPaused` while paused.
    /// Called by accounts on every permit (one external call for both checks).
    function activeProtocolFee(address token, uint256 value) external view returns (uint256);

    // custodial mode
    function predictForwarder(address treasury, address sweeper, bytes32 salt) external view returns (address);
    function deployForwarder(address treasury, address sweeper, bytes32 salt) external returns (address);
    function sweep(address treasury, address sweeper, bytes32 salt, address token) external returns (uint256);
    function sweepMany(SweepItem[] calldata items) external;

    // permit mode
    function predictAccount(address owner, uint256 index) external view returns (address);
    function deployAccount(address owner, uint256 index) external returns (address);
    /// @notice Deploys `p.owner`'s account at `index` if needed, then executes the permit.
    function deployAndPermit(uint256 index, Permit calldata p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs)
        external
        returns (address);
    /// @notice Claims the caller's accrued fees in `token` from each account to `to`.
    function claimMany(address[] calldata accounts, address token, address to) external returns (uint256 total);
}
