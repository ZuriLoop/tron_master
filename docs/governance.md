---
title: "Governance"
description: "Roles, the upgrade timelock, the guardian veto, and bounded pauses."
icon: "landmark"
---

Governance lives entirely in `PaymasterFactory`. Clones have no admin functions.

## Parameters (immutable per factory)

| Parameter | Bounds | Meaning |
|---|---|---|
| `UPGRADE_DELAY` | 2–30 days | minimum wait between queueing and executing an upgrade or role change |
| `EXECUTION_WINDOW` | 7 days (constant) | a queued action lapses if not executed in time |
| `PAUSE_DURATION` | 1 s – 14 days | every pause expires after this |
| `MAX_BPS`, `MAX_CAP` | `MAX_BPS <= 10000` | ceiling for the protocol fee |
| `FEE_TOKEN`, `FEE_RECIPIENT` | — | the token the protocol fee is charged in, and who claims it |

## Roles

- **admin.** Queues upgrades and role changes, sets the fee within the caps, and can pause, re-pause and unpause.
- **guardian.** Vetoes queued upgrades, pauses (with limits) and unpauses.

Both are intended to be **separate Tron multi-signature accounts**: for example a 3-of-5 admin and a 2-of-3 guardian held by different people. To the contracts each is just an address.

## Upgrades

```
admin:    queueUpgrade(kind, impl)    → UpgradeQueued(kind, impl, eta = now + UPGRADE_DELAY)
anyone:   executeUpgrade(kind)        → requires eta <= now <= eta + EXECUTION_WINDOW
admin or guardian: cancelUpgrade(kind)
```

- `impl` must have code, and `impl.FACTORY()` must equal this factory. That is a sanity check, not a safety proof: review the code.
- Queueing again replaces the pending upgrade and restarts the delay.
- Storage: `PermitAccount` keeps state in the ERC-7201 namespace `tronpaymaster.storage.PermitAccount`. A new implementation must keep that struct's layout and only append fields. `DepositForwarder` is stateless.
- Addresses never change, because clones point at the immutable router.

**What users should do.** Watch `UpgradeQueued` (`tron-paymaster gov watch` alerts on it). If you do not trust a queued implementation, withdraw before `eta`. The CLI shows pending upgrades with `tron-paymaster info`.

## Roles change

```
admin:      queueRoles(newAdmin, newGuardian)   → eta = now + UPGRADE_DELAY
admin:      cancelRoles()
newAdmin:   executeRoles()                      → proves the incoming admin is controlled
```

The guardian cannot cancel a role change, so a compromised guardian can always be replaced.

## Pause

```
guardian: pause()   only if not paused and now >= guardianPauseAvailableAt
                    sets pausedUntil = now + PAUSE_DURATION
                    sets guardianPauseAvailableAt = pausedUntil + PAUSE_DURATION
admin:    pause()   any time (re-pausing extends)
admin:    unpause() always; guardian: only a pause the guardian itself set
```

A pause affects:

- **Blocked:** `permitTransfer`, `deployAndPermit`, forwarder sweeps (direct or through the factory).
- **Never blocked:** `withdraw`, `withdrawTRX`, `setSigner`, `invalidateNonces`, `claimFees`, deployments, predictions, reads.

## Fee

`setProtocolFee(bps, cap)` is admin-only, with `bps <= MAX_BPS` and `cap <= MAX_CAP`. It takes effect immediately, but each permit's signed `maxFee` bounds what that transfer pays.

## Watching governance

`tron-paymaster gov watch` alerts on every queued, executable, executed or cancelled upgrade or role change, on pauses, and on fee changes. Run it, or an equivalent, wherever funds sit in these contracts. The timelock only protects people who are watching.

## Failure scenarios

| Compromise | Impact | Recovery |
|---|---|---|
| Guardian key | griefing: vetoes upgrades; pauses at most once per two `PAUSE_DURATION`s. It cannot unpause an admin pause, so it cannot undo an emergency response | admin replaces the guardian through `queueRoles` (the guardian cannot block it) |
| Admin key | can queue a malicious upgrade or role change and set the fee up to the caps | guardian vetoes upgrades; users see the queue and exit within the delay. A role takeover cannot be vetoed, so admin key custody is the critical control |
| Both | malicious upgrade after the delay | users exit during the delay. This is the residual trust, documented in the README |
