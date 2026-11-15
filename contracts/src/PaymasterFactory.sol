// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/tron-contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/tron-contracts/utils/math/Math.sol";
import {IPaymasterFactory} from "./interfaces/IPaymasterFactory.sol";
import {IPermitAccount, Permit} from "./interfaces/IPermitAccount.sol";
import {DepositForwarder} from "./DepositForwarder.sol";
import {PermitAccount} from "./PermitAccount.sol";
import {ImplementationRouter} from "./ImplementationRouter.sol";

interface IHasFactory {
    function FACTORY() external view returns (address);
    function KIND() external view returns (IPaymasterFactory.Kind);
}

/// @title PaymasterFactory
/// @notice Deploys deposit forwarders and permit accounts at deterministic
/// addresses, and governs the implementation they run.
/// @dev The factory itself is not upgradeable. Clones point at an immutable
/// ImplementationRouter per kind, which resolves the current implementation
/// here on every call. See IPaymasterFactory for the governance guarantees.
///
/// `admin` and `guardian` are expected to be Tron multi-signature accounts:
/// keys rotate under Tron account permissions while the address stays fixed.
contract PaymasterFactory is IPaymasterFactory {
    uint256 public constant MIN_UPGRADE_DELAY = 2 days;
    uint256 public constant MAX_UPGRADE_DELAY = 30 days;
    uint256 public constant MAX_PAUSE_DURATION = 14 days;
    uint256 public constant EXECUTION_WINDOW = 7 days;
    uint16 private constant BPS_DENOMINATOR = 10_000;

    struct Config {
        address feeToken;
        address feeRecipient;
        uint16 maxBps;
        uint128 maxCap;
        uint16 bps;
        uint128 cap;
        address admin;
        address guardian;
        uint256 upgradeDelay;
        uint256 pauseDuration;
    }

    struct Fee {
        uint16 bps;
        uint128 cap;
    }

    struct PendingUpgrade {
        address implementation;
        uint64 eta;
    }

    struct PendingRoles {
        address admin;
        address guardian;
        uint64 eta;
    }

    address public immutable FEE_TOKEN;
    address public immutable FEE_RECIPIENT;
    uint16 public immutable MAX_BPS;
    uint128 public immutable MAX_CAP;
    uint256 public immutable UPGRADE_DELAY;
    uint256 public immutable PAUSE_DURATION;
    address public immutable FORWARDER_ROUTER;
    address public immutable ACCOUNT_ROUTER;

    Fee private _fee;
    address public admin;
    address public guardian;
    uint64 public pausedUntil;
    uint64 public guardianPauseAvailableAt;
    /// @notice True while the current pause was set by the admin. The guardian
    /// cannot unpause an admin pause, so a compromised guardian cannot undo an
    /// emergency response (it could before only be replaced after the role delay).
    bool public adminPaused;
    mapping(Kind => address) private _implementation;
    mapping(Kind => PendingUpgrade) private _pendingUpgrade;
    PendingRoles private _pendingRoles;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    constructor(Config memory c) {
        if (c.admin == address(0) || c.guardian == address(0)) revert InvalidConfig();
        if (c.upgradeDelay < MIN_UPGRADE_DELAY || c.upgradeDelay > MAX_UPGRADE_DELAY) revert InvalidConfig();
        if (c.pauseDuration == 0 || c.pauseDuration > MAX_PAUSE_DURATION) revert InvalidConfig();
        if (c.maxBps > BPS_DENOMINATOR || c.bps > c.maxBps || c.cap > c.maxCap) revert InvalidConfig();
        bool charges = c.maxBps != 0 && c.maxCap != 0;
        if (charges && (c.feeToken == address(0) || c.feeRecipient == address(0))) revert InvalidConfig();
        if (!charges && (c.maxBps != 0 || c.maxCap != 0)) revert InvalidConfig();

        FEE_TOKEN = c.feeToken;
        FEE_RECIPIENT = c.feeRecipient;
        MAX_BPS = c.maxBps;
        MAX_CAP = c.maxCap;
        UPGRADE_DELAY = c.upgradeDelay;
        PAUSE_DURATION = c.pauseDuration;

        FORWARDER_ROUTER = address(new ImplementationRouter(address(this), Kind.Forwarder));
        ACCOUNT_ROUTER = address(new ImplementationRouter(address(this), Kind.Account));
        _implementation[Kind.Forwarder] = address(new DepositForwarder(address(this)));
        _implementation[Kind.Account] = address(new PermitAccount(address(this), c.feeRecipient, c.feeToken));

        _fee = Fee(c.bps, c.cap);
        admin = c.admin;
        guardian = c.guardian;

        emit Upgraded(Kind.Forwarder, _implementation[Kind.Forwarder]);
        emit Upgraded(Kind.Account, _implementation[Kind.Account]);
        emit RolesUpdated(c.admin, c.guardian);
        emit ProtocolFeeUpdated(c.bps, c.cap);
    }

    // ============================================================ governance

    function implementation(Kind kind) external view returns (address) {
        return _implementation[kind];
    }

    function pendingUpgrade(Kind kind) external view returns (address, uint256) {
        PendingUpgrade memory u = _pendingUpgrade[kind];
        return (u.implementation, u.eta);
    }

    function pendingRoles() external view returns (address, address, uint256) {
        PendingRoles memory r = _pendingRoles;
        return (r.admin, r.guardian, r.eta);
    }

    function paused() public view returns (bool) {
        return block.timestamp < pausedUntil;
    }

    /// @notice Queues `newImplementation` for `kind`. Re-queuing restarts the delay.
    function queueUpgrade(Kind kind, address newImplementation) external onlyAdmin {
        if (newImplementation.code.length == 0) revert InvalidImplementation();
        // Sanity check: the implementation must be bound to this factory.
        try IHasFactory(newImplementation).FACTORY() returns (address f) {
            if (f != address(this)) revert InvalidImplementation();
        } catch {
            revert InvalidImplementation();
        }
        // A router must never be an implementation: its fallback delegatecalls
        // the current implementation (so it would answer KIND() correctly) and,
        // installed as one, it would delegatecall itself until out of energy.
        if (newImplementation == FORWARDER_ROUTER || newImplementation == ACCOUNT_ROUTER) {
            revert InvalidImplementation();
        }
        // Binds the implementation to its kind: queuing an account implementation
        // under Kind.Forwarder would let a forwarder's "treasury" act as an owner
        // and withdraw anywhere; queuing a router would delegatecall itself forever.
        try IHasFactory(newImplementation).KIND() returns (Kind k) {
            if (k != kind) revert InvalidImplementation();
        } catch {
            revert InvalidImplementation();
        }
        uint256 eta = block.timestamp + UPGRADE_DELAY;
        // forge-lint: disable-next-line(unsafe-typecast)
        _pendingUpgrade[kind] = PendingUpgrade(newImplementation, uint64(eta)); // timestamp + <= 30 days
        emit UpgradeQueued(kind, newImplementation, eta);
    }

    /// @notice Admin or guardian veto of a queued upgrade.
    function cancelUpgrade(Kind kind) external {
        if (msg.sender != admin && msg.sender != guardian) revert NotAuthorized();
        PendingUpgrade memory u = _pendingUpgrade[kind];
        if (u.eta == 0) revert NothingQueued();
        delete _pendingUpgrade[kind];
        emit UpgradeCancelled(kind, u.implementation, msg.sender);
    }

    /// @notice Applies a queued upgrade once its delay has passed. Anyone may call.
    function executeUpgrade(Kind kind) external {
        PendingUpgrade memory u = _pendingUpgrade[kind];
        _checkEta(u.eta);
        // The code could have been destroyed during the delay; a codeless target
        // would make every delegatecall a silent success.
        if (u.implementation.code.length == 0) revert InvalidImplementation();
        delete _pendingUpgrade[kind];
        _implementation[kind] = u.implementation;
        emit Upgraded(kind, u.implementation);
    }

    /// @notice Queues a change of admin and/or guardian. The guardian cannot
    /// veto this, so a compromised guardian can always be replaced.
    function queueRoles(address newAdmin, address newGuardian) external onlyAdmin {
        if (newAdmin == address(0) || newGuardian == address(0)) revert InvalidConfig();
        uint256 eta = block.timestamp + UPGRADE_DELAY;
        // forge-lint: disable-next-line(unsafe-typecast)
        _pendingRoles = PendingRoles(newAdmin, newGuardian, uint64(eta)); // timestamp + <= 30 days
        emit RolesQueued(newAdmin, newGuardian, eta);
    }

    function cancelRoles() external onlyAdmin {
        if (_pendingRoles.eta == 0) revert NothingQueued();
        delete _pendingRoles;
        emit RolesCancelled();
    }

    /// @notice Applies queued roles. Must be called by the incoming admin,
    /// which proves the new admin address is controlled.
    function executeRoles() external {
        PendingRoles memory r = _pendingRoles;
        _checkEta(r.eta);
        if (msg.sender != r.admin) revert NotAdmin();
        delete _pendingRoles;
        admin = r.admin;
        guardian = r.guardian;
        emit RolesUpdated(r.admin, r.guardian);
    }

    /// @notice Pauses permits and sweeps for `PAUSE_DURATION`. Never affects
    /// owner withdrawals. The guardian may pause only when not already paused
    /// and not within one `PAUSE_DURATION` after its previous pause ended, so
    /// it cannot keep the protocol paused on its own. The admin may re-pause.
    function pause() external {
        uint256 until = block.timestamp + PAUSE_DURATION;
        if (msg.sender == guardian) {
            if (paused()) revert AlreadyPaused();
            if (block.timestamp < guardianPauseAvailableAt) revert PauseCooldown();
            // forge-lint: disable-next-line(unsafe-typecast)
            guardianPauseAvailableAt = uint64(until + PAUSE_DURATION); // timestamp + <= 28 days
            adminPaused = false;
        } else if (msg.sender == admin) {
            adminPaused = true;
        } else {
            revert NotAuthorized();
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        pausedUntil = uint64(until); // timestamp + <= 14 days
        emit Paused(msg.sender, until);
    }

    function unpause() external {
        // The guardian may undo its own pause, never the admin's.
        if (msg.sender != admin && (msg.sender != guardian || adminPaused)) revert NotAuthorized();
        adminPaused = false;
        pausedUntil = 0;
        emit Unpaused(msg.sender);
    }

    // ================================================================= fees

    function bps() external view returns (uint16) {
        return _fee.bps;
    }

    function cap() external view returns (uint128) {
        return _fee.cap;
    }

    /// @notice Sets the protocol fee within the immutable maxima. Each permit's
    /// signed `maxFee` still bounds what a transfer can be charged.
    function setProtocolFee(uint16 newBps, uint128 newCap) external onlyAdmin {
        if (newBps > MAX_BPS || newCap > MAX_CAP) revert FeeAboveMax();
        _fee = Fee(newBps, newCap);
        emit ProtocolFeeUpdated(newBps, newCap);
    }

    function protocolFee(address token, uint256 value) public view returns (uint256) {
        if (token != FEE_TOKEN || token == address(0)) return 0;
        Fee memory f = _fee;
        if (f.bps == 0 || f.cap == 0) return 0;
        return Math.min(Math.mulDiv(value, f.bps, BPS_DENOMINATOR), f.cap);
    }

    function activeProtocolFee(address token, uint256 value) external view returns (uint256) {
        if (paused()) revert ProtocolPaused();
        return protocolFee(token, value);
    }

    // ======================================================== custodial mode

    function predictForwarder(address treasury, address sweeper, bytes32 salt) public view returns (address) {
        return _predict(FORWARDER_ROUTER, _forwarderArgs(treasury, sweeper), salt);
    }

    /// @notice Deploys a forwarder if needed. Permissionless and idempotent:
    /// the address commits to its treasury and sweeper, so deploying it on
    /// someone else's behalf changes nothing.
    function deployForwarder(address treasury, address sweeper, bytes32 salt) public returns (address forwarder) {
        if (treasury == address(0)) revert InvalidTreasury();
        bytes memory args = _forwarderArgs(treasury, sweeper);
        bool created;
        (forwarder, created) = _deploy(FORWARDER_ROUTER, args, salt);
        if (created) emit ForwarderDeployed(forwarder, treasury, sweeper, salt);
    }

    /// @notice Deploys the forwarder if needed, then sweeps `token` (or TRX
    /// for `address(0)`) to its treasury. Gated on `sweeper` when non-zero.
    function sweep(address treasury, address sweeper, bytes32 salt, address token) public returns (uint256) {
        if (sweeper != address(0) && msg.sender != sweeper) revert NotAuthorized();
        address forwarder = deployForwarder(treasury, sweeper, salt);
        return token == address(0)
            ? DepositForwarder(payable(forwarder)).sweepTRX()
            : DepositForwarder(payable(forwarder)).sweep(token);
    }

    /// @notice All-or-nothing batch of `sweep`.
    function sweepMany(SweepItem[] calldata items) external {
        for (uint256 i; i < items.length; ++i) {
            SweepItem calldata it = items[i];
            sweep(it.treasury, it.sweeper, it.salt, it.token);
        }
    }

    // ========================================================== permit mode

    function predictAccount(address owner, uint256 index) public view returns (address) {
        return _predict(ACCOUNT_ROUTER, abi.encodePacked(owner), _accountSalt(owner, index));
    }

    /// @notice Deploys an account if needed. Permissionless and idempotent.
    function deployAccount(address owner, uint256 index) public returns (address account) {
        if (owner == address(0)) revert InvalidConfig();
        bool created;
        (account, created) = _deploy(ACCOUNT_ROUTER, abi.encodePacked(owner), _accountSalt(owner, index));
        if (created) emit AccountDeployed(account, owner, index);
    }

    /// @notice Deploys the account if needed and executes a permit on it, so a
    /// first transfer needs one transaction.
    function deployAndPermit(uint256 index, Permit calldata p, uint256 relayerFee, address feeRecipient, bytes32 r, bytes32 vs)
        external
        returns (address account)
    {
        // The owner is p.owner by definition (permitTransfer enforces it), so a
        // separate argument would be 32 redundant bandwidth bytes.
        account = deployAccount(p.owner, index);
        IPermitAccount(account).permitTransfer(p, relayerFee, feeRecipient, r, vs);
    }

    /// @inheritdoc IPaymasterFactory
    /// @dev The beneficiary is always `msg.sender`; accounts trust the factory
    /// for this call only because of that.
    function claimMany(address[] calldata accounts, address token, address to) external returns (uint256 total) {
        for (uint256 i; i < accounts.length; ++i) {
            total += IPermitAccount(accounts[i]).claimFees(token, msg.sender, to);
        }
    }

    // ============================================================= internal

    /// @dev CREATE2 address prefix: 0x41 on TVM. Overridden to 0xff only in
    /// the EVM test harness; this is the sole tested-vs-deployed difference.
    function _create2Prefix() internal pure virtual returns (bytes1) {
        return 0x41;
    }

    function _checkEta(uint64 eta) private view {
        if (eta == 0) revert NothingQueued();
        if (block.timestamp < eta) revert TooEarly();
        if (block.timestamp > uint256(eta) + EXECUTION_WINDOW) revert TooLate();
    }

    function _forwarderArgs(address treasury, address sweeper) private pure returns (bytes memory) {
        return abi.encodePacked(treasury, sweeper);
    }

    function _accountSalt(address owner, uint256 index) private pure returns (bytes32) {
        return keccak256(abi.encode(owner, index));
    }

    /// @dev Same bytes as OpenZeppelin Clones' immutable-args init code
    /// (private there, so replicated; parity is covered by tests).
    function _initCode(address router, bytes memory args) private pure returns (bytes memory) {
        return abi.encodePacked(
            hex"61",
            uint16(args.length + 0x2d),
            hex"3d81600a3d39f3363d3d373d3d3d363d73",
            router,
            hex"5af43d82803e903d91602b57fd5bf3",
            args
        );
    }

    function _predict(address router, bytes memory args, bytes32 salt) private view returns (address) {
        bytes32 h = keccak256(abi.encodePacked(_create2Prefix(), address(this), salt, keccak256(_initCode(router, args))));
        return address(uint160(uint256(h)));
    }

    function _deploy(address router, bytes memory args, bytes32 salt)
        private
        returns (address instance, bool created)
    {
        instance = _predict(router, args, salt);
        if (instance.code.length != 0) return (instance, false);
        address deployed = Clones.cloneDeterministicWithImmutableArgs(router, args, salt);
        if (deployed != instance) revert PredictionMismatch();
        return (instance, true);
    }
}
