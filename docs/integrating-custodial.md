---
title: "Custodians & exchanges"
description: "Deposit addresses that can only pay your treasury, swept in one transaction."
icon: "building-columns"
---

The guide is for platforms that hold user deposits: exchanges, payment processors, and custodial wallets running MPC or HSM signers. The result is per-user Tron deposit addresses that need no TRX, no activation and no per-address energy, swept to one treasury.

## 1. Decide the shape

| Choice | Recommendation |
|---|---|
| Treasury | A Tron **multi-signature account** (keys can rotate; the address, which is baked into every deposit address, never changes). One treasury per hot wallet |
| Sweeper | `address(0)` (anyone may sweep, funds still only reach the treasury) **or** a dedicated sweeper address if deposits must be screened before reaching the treasury |
| Salt scheme | `deriveDepositSalt(secret, id)` = HMAC-SHA256. Keep `secret` in your secret manager; `id` is your stable user or invoice id |
| Factory | A deployment whose governance you have reviewed (see [governance.md](governance.md)) |

Each change of treasury, sweeper or salt produces a different address, so pick these deliberately.

## 2. Generate deposit addresses (offline)

```ts
const client = createPaymasterClient({ chain: tronMainnet, factory });
const { forwarderRouter } = await client.getDeployment();          // cache: immutable
await client.predictForwarder(treasury, await deriveDepositSalt(secret, "probe")); // one on-chain cross-check

for (const userId of users) {
  const salt = await deriveDepositSalt(secret, `user:${userId}`);
  const address = getForwarderAddress({ factory, forwarderRouter, treasury, salt });
  // store (userId → address); the salt can always be re-derived
}
```

Rules:
- **Never accept an address from an API or relayer.** Recompute it.
- Run `assertFactoryDeployed` (which `getDeployment` does) on the network you serve, so you never hand out an address for the wrong network.

## 3. Detect deposits

Forwarders run no code when funds arrive. For a plain TRX transfer, no code runs at all. Detect deposits the way you already do:

- **TRC-20:** `Transfer(from, to = depositAddress, value)` logs from your token contracts
- **TRX:** account balance changes, or `TransferContract`s to the address

Credit users on your usual confirmation depth. A deposit address is valid **before** its contract exists.

## 4. Sweep

```ts
const sweeper = createPaymasterClient({ chain, factory, signer: sweeperSigner });
await sweeper.sweep({ treasury, salt, token: USDT });           // deploys on first use
await sweeper.sweepMany(items);                                  // batch, all-or-nothing
```

- The first sweep of an address deploys the forwarder in the same transaction (measured on Nile at 76.6k energy, versus 24.3k for later sweeps). Mainnet is dearer: USDT carries a dynamic-energy penalty that a testnet does not, so measure there before pricing anything.
- **Thresholds.** Sweeping costs energy, so set a per-token minimum, e.g. sweep USDT above 20 and TRX above 50.
- **Batches.** Size them by the per-transaction CPU limit (about 80 ms). Measure on Nile, and keep batches modest (e.g. 10–20).
- **Token allowlist.** Anyone can send junk tokens to your addresses. Only sweep tokens you list, and simulate first (the client does).
- **Energy.** The sweeper pays. Rent energy in blocks (TronSave, JustLend) or stake. `feeLimit` must cover `energy × price` even when you hold rented energy. The client sets it from the simulation.

### Signing with a policy engine

A sweep is one ordinary `TriggerSmartContract`:

```
to:   PaymasterFactory
data: sweep(address treasury, address sweeper, bytes32 salt, address token)
```

A policy engine that parses Tron transactions can therefore pin the contract, the selector and the `treasury` argument. A leaked sweeper credential can then only move deposits into your own treasury. [`examples/turnkey`](https://github.com/ZuriLoop/tron-paymaster/tree/main/examples/turnkey) shows this policy for Turnkey.

## 5. Managed sweeping

With `sweeper = address(0)`, a third party can run sweeps for you and pay the energy, with zero ability to redirect funds. The forwarder's code only ever pays the treasury in its own address. This lets you outsource sweeping without granting any signing authority.

## 6. Monitor

Run `tron-paymaster gov watch` (see [governance.md](governance.md)). It turns the governance changes below into alerts, with no event indexer needed.

| Event | Meaning | Action |
|---|---|---|
| `ForwarderDeployed(forwarder, treasury, sweeper, salt)` | first sweep of an address | none |
| `UpgradeQueued(kind, impl, eta)` | the forwarder code may change at `eta` | review `impl`; if unacceptable, sweep everything before `eta` and stop issuing addresses |
| `Paused(by, until)` | sweeps blocked until `until` | queue sweeps for later |
| `RolesQueued` / `RolesUpdated` | governance keys changing | review |

## 7. Failure modes

| Symptom | Cause |
|---|---|
| `NotAuthorized` | a gated forwarder (`sweeper != 0`) was called by someone else |
| `ProtocolPaused` | wait for the pause to expire, or for the guardian or admin to unpause |
| `TransferFailed` | the token's transfer reverted, or it moved less than its balance (fee-on-transfer tokens are unsupported) |
| `OUT_OF_ENERGY` / `OUT_OF_TIME` | `feeLimit` too low or batch too large |

## 8. Paying users out

Deposits are only half a platform. Withdrawals go the other way through a
PermitAccount: fund one account, sign a permit per payout, and a relayer
executes on Tron. The signing key never builds a Tron transaction, so an HSM or
policy engine only ever sees typed data, and the account needs no TRX.

Three properties decide whether a payout run is safe to re-run, and all three
are easy to get wrong:

| Property | Consequence of ignoring it |
|---|---|
| One account has **one nonce**, consumed in order | parallel payouts race for the same nonce; one is guaranteed to fail, so a batch silently develops holes |
| The idempotency key must come from **your** payout reference, not a random id | a crash between submitting and recording pays twice on the next run |
| A reverted permit **does not consume** the nonce | treating a failure as progress skips the next payout |

[`examples/payouts`](https://github.com/ZuriLoop/tron-paymaster/tree/main/examples/payouts)
is a runnable implementation of all three, with a resumable ledger, per-payout
fee caps, and a `--dry-run` that prices a batch before anything is signed.
