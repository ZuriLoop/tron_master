---
title: "How it works"
description: "The two modes, the shared factory, deterministic addresses, and the upgrade path."
icon: "diagram-project"
---

TronPaymaster lets a Tron address move tokens without holding TRX or energy. Someone else pays the network cost, and the cost is settled in the token being moved. It is a paymaster in the ERC-4337 *sense*: sponsored gas, fees paid in a token. It does **not** implement ERC-4337. Tron has no EntryPoint, bundlers or UserOps.

It has two modes, which share one factory:

| | DepositForwarder | PermitAccount |
|---|---|---|
| Custody | Custodial (an exchange, wallet provider or payment processor) | Non-custodial (the user holds the key) |
| Who moves funds | The custodian's sweeper, or anyone | Any relayer, on the owner's signature |
| Where funds can go | Only to the treasury fixed in the address | Anywhere the owner signs for |
| Fee | None on-chain. The sweeper pays its own energy | Relayer fee + protocol fee, in the token, capped by the signed `maxFee` |
| Typical use | Per-user deposit addresses swept to a hot wallet | Gasless USDT sends from a user wallet |

---

## 1. The problem on Tron

Every Tron transaction consumes **bandwidth** and, for contract calls, **energy**. An address without TRX, or staked or delegated energy, cannot send a TRC-20 transfer. A fresh address cannot even be activated without TRX. There are two workarounds:

- **Delegating or renting energy** to each address. This needs the address activated first, has a delegation lag, and needs per-address bookkeeping.
- **Sending TRX to each address.** This costs a TRX transfer per address, leaves dust behind, and has a price that moves with TRX.

TronPaymaster removes both. Funds sit at an address whose code (deployed on first use) only moves them according to fixed rules. The party that moves them pays the energy from its own account.

## 2. Components

```
                         ┌──────────────────────────────┐
                         │       PaymasterFactory       │  not upgradeable
                         │  - CREATE2 deployer          │
                         │  - implementation registry   │  ← timelocked upgrades
                         │  - pause / fee / roles       │
                         └──────┬───────────────┬───────┘
                 FORWARDER_ROUTER│               │ACCOUNT_ROUTER   (immutable)
                         ┌───────▼─────┐   ┌─────▼───────┐
                         │ Implementation│ │ Implementation│
                         │    Router     │ │    Router     │  fixed delegate target
                         └───────▲─────┘   └─────▲───────┘
            delegatecall│(clone) │               │ (clone)│delegatecall
             ┌──────────┴───┐  ┌─┴────────────┐  ┌┴─────────────┐
             │ forwarder #1 │  │ forwarder #2 │  │  account #1  │  … one per deposit / owner
             │ args:        │  │              │  │ args: owner  │
             │ treasury ‖   │  │              │  │ storage:     │
             │ sweeper      │  │              │  │ nonce, fees  │
             └──────────────┘  └──────────────┘  └──────────────┘
                  │ router resolves factory.implementation(kind) and delegatecalls:
                  ▼
        DepositForwarder (impl)            PermitAccount (impl)
```

- **PaymasterFactory.** It deploys clones, holds the current implementation for each kind, and owns governance: timelocked upgrades, a bounded pause, the protocol fee and roles. The factory itself is immutable. A new factory is a new deployment.
- **ImplementationRouter** (one per kind, deployed by the factory constructor). It is a tiny immutable contract. On every call it reads `factory.implementation(KIND)` and delegatecalls it. Every clone delegates to its router, never directly to an implementation, so **a clone's address never depends on which implementation is current**.
- **Clones.** These are EIP-1167 minimal proxies with *immutable args* appended to their runtime code (OpenZeppelin `Clones.cloneDeterministicWithImmutableArgs`):
  - a forwarder's args are `treasury ‖ sweeper` (40 bytes)
  - an account's args are `owner` (20 bytes)

  The args are part of the CREATE2 init code, so they are part of the address. There is **no initializer**, so nothing can be front-run or hijacked.
- **Implementations.** These are `DepositForwarder` (stateless) and `PermitAccount` (ERC-7201 namespaced storage). Both refuse to run when called directly. Each checks `address(this) != SELF`.

Call path for, say, `account.permitTransfer(...)`:

```
relayer ──tx──▶ clone ──delegatecall──▶ router ──staticcall factory.implementation(Account)
                                              └─delegatecall──▶ PermitAccount code
                                                  (address(this) = clone, storage = clone's)
```

The implementation reads its args with `Clones.fetchCloneArgs(address(this))`, i.e. `EXTCODECOPY` of the clone's own code.

## 3. Deterministic addresses

Addresses are computed with **TVM CREATE2**. It is identical to EVM CREATE2 except that the prefix byte is `0x41` instead of `0xff`:

```
address = last20( keccak256( 0x41 ‖ factory ‖ salt ‖ keccak256(initCode) ) )
initCode = 0x61 ‖ uint16(len(args)+0x2d) ‖ 3d81600a3d39f3363d3d373d3d3d363d73
           ‖ router ‖ 5af43d82803e903d91602b57fd5bf3 ‖ args
```

| Kind | salt | args |
|---|---|---|
| Forwarder | caller-chosen 32 bytes (the SDK derives `HMAC-SHA256(secret, "tron-paymaster/deposit-salt/v1:" ‖ id)`) | `treasury ‖ sweeper` |
| Account | `keccak256(abi.encode(owner, index))` | `owner` |

Consequences:

- **Addresses are known before deployment.** Deposits can arrive at an address with no code, and TVM credits TRC-20 balances and TRX to it. Deploying the clone later does not change the address, and an address already activated by a TRX transfer still deploys. Both cases are tested on a real node.
- **Addresses are derivable offline.** The SDK computes them from `(factory, router, args, salt)` without a network call. The factory exposes `predictForwarder` and `predictAccount`. The SDK's `PaymasterClient` cross-checks its own computation against the factory and throws on any mismatch.
- **Changing an arg changes the address.** A forwarder for treasury A can never send to treasury B, because a forwarder for B is a different address.
- **Upgrades never move addresses.** The init code commits to the router, which is immutable, not to the implementation.

The factory computes predictions itself, through a `virtual _create2Prefix()` that returns `0x41`. It asserts that the deployed address equals the prediction (`PredictionMismatch`). The Foundry (EVM) test harness overrides the prefix to `0xff`. That override is the only difference between the tested and the deployed contracts.

## 4. Custodial mode: DepositForwarder

### Flow

```
1. custodian derives deposit address offline      salt = HMAC(secret, userId)
                                                   addr = predictForwarder(treasury, sweeper, salt)
2. user sends USDT (or TRX) to addr               (no contract there yet; balances still credit)
3. sweeper calls factory.sweep(treasury, sweeper, salt, token)
      ├─ deploys the clone if it has no code       (one tx: deploy + sweep)
      └─ forwarder.sweep(token): full balance → treasury
4. later deposits: forwarder.sweep(token) directly, or factory.sweep again
```

### Rules

- `sweep(token)` and `sweepTRX()` move the **entire balance**, and always to `treasury`.
- When `sweeper == 0`, anyone may trigger a sweep. A third party who pays to sweep gains nothing, because the funds still land in the treasury. This enables trust-minimized *managed sweeping*: a service can sweep for a custodian without ever having the ability to redirect funds.
- When `sweeper != 0`, only the sweeper (directly, or through the factory) may trigger. Use this when deposits must be screened before they reach the treasury. It never changes *where* funds can go.
- There is no protocol fee in forwarders. A sweep empties the forwarder, so taking a fee would cost a second token transfer each time. Minimum-sweep thresholds are off-chain policy.
- A plain TRX transfer on Tron runs no contract code, so a forwarder cannot "detect" a deposit. Detection is the custodian's indexer's job, through TRC-20 `Transfer` logs or account balances.
- **Recommended treasury:** a Tron multi-signature account. Keys can rotate under Tron account permissions while the address, and so every forwarder bound to it, stays the same.

### Batch

`sweepMany(SweepItem[])` sweeps many forwarders in one transaction and is all-or-nothing. Size batches by the per-transaction CPU time limit (about 80 ms on mainnet), not just by energy. Measure on Nile before relying on a batch size.

## 5. Non-custodial mode: PermitAccount

### Flow (through a relayer)

```
owner (no TRX)            relayer                          chain
   │  quote(owner,to,value) │                                 │
   │───────────────────────▶│ prices energy, binds itself     │
   │◀────── unsigned permit │ (relayer, maxFee, nonce, ttl)   │
   │ sign TIP-712 digest    │                                 │
   │──── permit + (r,vs) ──▶│ verify sig locally, simulate    │
   │                        │── permitTransfer / deployAndPermit ─▶ account
   │                        │                                 │  checks → effects → transfer
   │◀──────────── txid ─────│                                 │  recipient += value
   │                        │                                 │  fees accrue in account storage
   │                        │── claimMany (later, batched) ──▶│  relayer's accrual paid out
```

### What the account checks (cheapest first)

1. `block.timestamp <= deadline`
2. `nonce == account.nonce`, so nonces are sequential and each executes at most once
3. `permit.owner == OWNER`
4. `permit.relayer == 0 || feeRecipient == permit.relayer`. This is the relayer binding: a front-runner who copies the permit cannot redirect the fee.
5. `relayerFee != 0 ⇒ feeRecipient != 0`
6. `to ∉ {0, this}` and `value > 0`
7. `ECDSA.recover(digest, r, vs) == signer` (the rotated signer, or `OWNER` when none is set). High-s signatures are rejected.
8. `relayerFee + protocolFee <= maxFee`. The protocol fee is read live from the factory, and that call reverts while the protocol is paused.

Then the effects: the nonce increments, and fees are credited to `totalOwed`, `protocolOwed` and `feeOwed[token][feeRecipient]`. Next comes `TokenTransfer.send(to, value)`. The final check is `balanceOf(this) >= totalOwed[token]`, which ensures accrued fees are always backed.

The recipient receives **exactly `value`**. Fees are taken separately, from the account's remaining balance.

### Lazy fee accrual

Fees are recorded in account storage, not transferred on each permit. One permit therefore costs one token transfer, not three. Relayers and the fee recipient later claim in bulk, with `claimMany(accounts, token, to)` on the factory. That call pays only the *caller's own* accrual. For the fee recipient it also pays the protocol fee. The owner's withdrawable balance is `available = balance − totalOwed`.

### Owner controls (never paused)

| Function | Purpose |
|---|---|
| `withdraw(token, to, amount)` / `withdrawTRX` | Exit. `amount <= available` |
| `setSigner(addr)` | Rotate the permit key. Gated on `msg.sender`, which follows Tron account permissions, so an owner who has moved their account to multi-signature can revoke the original key's permit authority. `0` restores the owner key |
| `invalidateNonces(n)` | Cancel every outstanding permit below `n` |

An owner exit is a normal transaction, so the owner needs TRX or energy to send it. An owner without TRX can instead exit through a relayer, by signing a permit to themselves.

### Excluded on purpose

- **A generic `execute`.** An owner `approve` would let accrued fees be drained via `transferFrom`.
- **TRC-10 tokens** (a documented gap).
- **Fee-on-transfer and rebasing tokens.** They are unsupported: the balance check guards the sender side only.

## 6. Fees

```
protocolFee(token, value) = token == FEE_TOKEN ? min(value · bps / 10⁴, cap) : 0
```

- There is one fee token per factory, because the cap is denominated in that token. Other tokens pay no protocol fee.
- `bps` and `cap` can be changed by the admin within the immutable `MAX_BPS` and `MAX_CAP`. Every permit's signed `maxFee` bounds what a single transfer can pay, so a fee raise can never take more than the owner signed for.
- The relayer fee is set by the relayer's quote, and the account enforces only the ceiling the owner signed (`maxFee`). A relayer typically prices it as `(energy × energyPrice + bandwidth × 1000 sun)` converted to the token, plus a margin — but what it charges is its own business, and competing on that is the point of relaying being permissionless.

## 7. Governance

See [governance.md](governance.md) for full details. In summary:

- **Upgrades.** The admin queues an implementation, and it can only be executed after `UPGRADE_DELAY`. That delay is immutable, at least 48h and at most 30d. A queued upgrade lapses if not executed within 7 days, and the guardian can veto it. Queued upgrades are public events, so owners have the whole delay to withdraw.
- **Roles.** Admin and guardian changes go through the same delay and are executed by the incoming admin. The guardian cannot veto its own replacement.
- **Pause.** The guardian or admin can pause. A pause blocks permits and sweeps only, and expires after the immutable `PAUSE_DURATION` (at most 14d). The guardian cannot pause again until one more `PAUSE_DURATION` has passed after its previous pause ends.
- **Never pausable:** `withdraw`, `withdrawTRX`, `setSigner`, `invalidateNonces`, `claimFees`.
- **Recommended:** admin and guardian are separate Tron multi-signature accounts.

## 8. Token transfers on Tron

Tron's USDT `transfer` returns `false` **on success**, which makes OpenZeppelin's SafeERC20 revert. Ignoring the return value is also unsafe, because a token that fails silently would let a permit consume its nonce and fees without moving funds. `TokenTransfer.send` therefore:

1. calls `transfer` and requires that the call did not revert
2. ignores the returned bool
3. requires that `balanceBefore − balanceAfter >= amount`

## 9. Energy and who pays

Tron charges the **caller** for execution energy when the contract's `consume_user_resource_percent` is 100. The factory is deployed with 100, and CREATE2 clones get 100 by default. So the relayer or sweeper pays everything, and the deployer subsidizes nothing. The end-to-end test asserts `origin_energy_usage == 0` on real receipts.

Only mainnet-simulated energy figures should be quoted anywhere. A local node and Nile have no USDT dynamic-energy penalty, so their figures understate mainnet cost substantially, and the penalty moves with the token's overall usage rather than yours.

## 10. Trust summary

| Who | Can | Cannot |
|---|---|---|
| Owner (PermitAccount) | withdraw `available` at any time; rotate the signer; cancel permits | spend accrued fees |
| Relayer | submit valid signed permits; claim its own accrued fees | change the recipient or amount; take more than `maxFee`; redirect another relayer's fee |
| Sweeper / anyone | trigger forwarder sweeps (gated if a sweeper is set) | send forwarder funds anywhere but the treasury |
| Admin | queue upgrades (delayed); set the fee within the caps; queue role changes (delayed); pause | upgrade instantly; raise the fee above the caps or above a permit's `maxFee`; move funds directly |
| Guardian | veto upgrades; pause (bounded, with cooldown); unpause | upgrade; change the fee; keep the protocol paused indefinitely; block its own replacement |
| Deployer (Tron-level) | `UpdateSetting` / `UpdateEnergyLimit` on the factory's resource settings | touch funds or code |

**Residual trust.** After the delay, an executed upgrade can change the code behind every clone of that kind. The protections are the public queue, the delay, the guardian veto, and owners' ability to exit within the window. Token issuers keep their own powers (USDT can freeze addresses). Nothing in these contracts can freeze funds.
