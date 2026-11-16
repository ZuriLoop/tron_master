---
title: "Contract reference"
description: "Contracts, functions, events, and errors."
icon: "file-code"
---

The canonical signatures are in `contracts/src/interfaces/`. "Pausable" means the call reverts with `ProtocolPaused` while the factory is paused.

## PaymasterFactory

### Configuration (immutable)

| Function | Returns |
|---|---|
| `FEE_TOKEN()`, `FEE_RECIPIENT()` | protocol fee token and its recipient |
| `MAX_BPS()`, `MAX_CAP()` | fee ceilings |
| `UPGRADE_DELAY()`, `PAUSE_DURATION()` | governance timings |
| `EXECUTION_WINDOW()` | 7 days |
| `MIN_UPGRADE_DELAY()`, `MAX_UPGRADE_DELAY()`, `MAX_PAUSE_DURATION()` | constructor bounds |
| `FORWARDER_ROUTER()`, `ACCOUNT_ROUTER()` | clone targets (part of every address) |

### State

| Function | Returns |
|---|---|
| `admin()`, `guardian()` | current roles |
| `implementation(kind)` | current implementation (`0` = Forwarder, `1` = Account) |
| `pendingUpgrade(kind)` | `(implementation, eta)` |
| `pendingRoles()` | `(admin, guardian, eta)` |
| `paused()`, `pausedUntil()`, `guardianPauseAvailableAt()` | pause state |
| `bps()`, `cap()` | current fee |
| `protocolFee(token, value)` | fee for a transfer |
| `activeProtocolFee(token, value)` | same; reverts `ProtocolPaused` while paused |

### Custodial

| Function | Access | Notes |
|---|---|---|
| `predictForwarder(treasury, sweeper, salt)` | view | |
| `deployForwarder(treasury, sweeper, salt)` | anyone | idempotent |
| `sweep(treasury, sweeper, salt, token)` | anyone if `sweeper == 0`, else the sweeper | deploys if needed; `token == 0` sweeps TRX; pausable |
| `sweepMany(SweepItem[])` | as `sweep` | all-or-nothing |

### Permit mode

| Function | Access | Notes |
|---|---|---|
| `predictAccount(owner, index)` | view | |
| `deployAccount(owner, index)` | anyone | idempotent |
| `deployAndPermit(owner, index, permit, relayerFee, feeRecipient, r, vs)` | anyone | pausable |
| `claimMany(accounts, token, to)` | anyone | pays the caller's own accrual |

### Governance

| Function | Access |
|---|---|
| `queueUpgrade(kind, impl)` | admin |
| `cancelUpgrade(kind)` | admin, guardian |
| `executeUpgrade(kind)` | anyone, within `[eta, eta + 7d]` |
| `queueRoles(admin, guardian)`, `cancelRoles()` | admin |
| `executeRoles()` | incoming admin, within `[eta, eta + 7d]` |
| `pause()` | admin; guardian when not paused and out of cooldown |
| `unpause()` | admin; guardian only for its own pause |
| `setProtocolFee(bps, cap)` | admin, within the maxima |

### Events

- `ForwarderDeployed(forwarder, treasury, sweeper, salt)`
- `AccountDeployed(account, owner, index)`
- `ProtocolFeeUpdated(bps, cap)`
- `UpgradeQueued(kind, implementation, eta)`, `UpgradeCancelled(kind, implementation, by)`, `Upgraded(kind, implementation)`
- `RolesQueued(admin, guardian, eta)`, `RolesCancelled()`, `RolesUpdated(admin, guardian)`
- `Paused(by, until)`, `Unpaused(by)`

### Errors

| Error | Cause |
|---|---|
| `InvalidTreasury` | zero treasury |
| `InvalidConfig` | constructor bounds, zero role, or zero owner |
| `InvalidImplementation` | no code, or `FACTORY()` ≠ this factory |
| `NotAuthorized` / `NotAdmin` | wrong caller |
| `FeeAboveMax` | fee above the maxima |
| `PredictionMismatch` | deployed address ≠ prediction (should be unreachable) |
| `NothingQueued`, `TooEarly`, `TooLate` | timelock state |
| `AlreadyPaused`, `PauseCooldown` | guardian pause limits |
| `ProtocolPaused` | permits or sweeps while paused |

## DepositForwarder (per clone)

| Function | Access | Notes |
|---|---|---|
| `treasury()`, `sweeper()`, `FACTORY()` | view | |
| `sweep(token) returns (amount)` | anyone if `sweeper == 0`, else the sweeper or the factory | full balance to the treasury; pausable |
| `sweepTRX() returns (amount)` | same | |

Errors: `NotAuthorized`, `DirectCallForbidden` (implementation called directly), `TransferFailed`.

## PermitAccount (per clone)

| Function | Access | Pausable |
|---|---|---|
| `permitTransfer(permit, relayerFee, feeRecipient, r, vs)` | anyone with a valid permit | yes |
| `withdraw(token, to, amount)`, `withdrawTRX(to, amount)` | owner | **never** |
| `setSigner(signer)`, `invalidateNonces(n)` | owner | **never** |
| `claimFees(token, beneficiary, to)` | the beneficiary, or the factory | never |
| `owner()`, `signer()`, `nonce()`, `available(token)`, `totalOwed(token)`, `protocolOwed(token)`, `feeOwed(token, who)` | view | |
| `domainSeparator()`, `hashPermit(permit)`, `eip712Domain()` | view | |

**Events:**
- `PermitExecuted(nonce, token, to, value, relayerFee, protocolFee, feeRecipient)`
- `FeesClaimed(token, beneficiary, to, amount)`
- `Withdrawn(token, to, amount)` (`token == 0` for TRX)
- `NoncesInvalidated(newNonce)`
- `SignerUpdated(signer)`

**Errors:**
- permit checks: `Expired`, `BadNonce`, `BadOwner`, `BadSignature`, `RelayerMismatch`, `FeeExceedsMax`
- balance and recipient: `InsufficientAvailable`, `InvalidRecipient`, `ZeroValue`
- owner and access: `NotOwner`, `NotAuthorized`, `InvalidNonce`
- other: `DirectCallForbidden`, `TransferFailed`, OpenZeppelin `ECDSAInvalidSignature*`

Storage: ERC-7201 namespace `tronpaymaster.storage.PermitAccount` at slot `0x9b298f66…641e00`.
