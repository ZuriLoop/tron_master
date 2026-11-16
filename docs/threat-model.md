---
title: "Threat model"
description: "What can go wrong, who can do what, and the residual trust."
icon: "shield-halved"
---

## Assets

- user tokens and TRX in PermitAccounts
- custodial deposits in DepositForwarders
- accrued relayer and protocol fees

## Invariants (tested)

| # | Invariant | Where |
|---|---|---|
| I1 | `balanceOf(account) >= totalOwed` after every call | invariant suite, e2e |
| I2 | `totalOwed == protocolOwed + Σ feeOwed` | invariant suite |
| I3 | `withdraw(available)` always succeeds for the owner | invariant suite |
| I4 | fees ≤ `maxFee`; the recipient gets exactly `value` | invariant handler, unit |
| I5 | each nonce executes at most once; the nonce is monotonic | invariant handler, unit |
| I6 | fee ≤ immutable maxima; immutables constant; upgrades never before their eta; pauses bounded; guardian cooldown | governance invariant suite |
| I7 | forwarder value only reaches the treasury, for any caller and calldata | fuzz + forwarder invariant suite |
| I8 | claims reduce only the claimant's own accrual | unit, invariant |
| I9 | implementations and routers revert when called directly | unit |
| I10 | only the owner (`msg.sender`) rotates the signer; the old key's permits then fail | unit |

## Threats and mitigations

**Permit phishing.** A signed permit has no on-chain allowance, so revocation tools cannot see it. Mitigations:
- single-use, exact-amount permits
- short default deadlines (180 s)
- relayer binding
- sequential nonces
- `invalidateNonces`
- `setSigner` rotation

Wallets should display the decoded `PermitTransfer` fields.

**Front-running a submitted permit.** Anyone can submit the permit, but with `relayer` set, the fee credit can only go to that relayer. Without a binding, the first submitter takes the fee. The transfer itself is the same either way.

**Malicious relayer quotes.** What gets signed is the permit, not the quote UI. `relayer.quote()` verifies every permit field against the request and the quoted fees, and bounds the deadline, so a relayer cannot have a larger `maxFee` or a day-long deadline signed than it displayed. Wallets should still render the decoded permit.

**Relayer griefing.** Invalid permits waste only the relayer's own simulation, since checks run cheapest first. The reference relayer:
- verifies signatures locally
- simulates with the real calldata before broadcasting
- refuses calls that cost far more energy than it priced
- rate-limits per owner

**Malicious tokens.** Accounting is per token, so a malicious token can only corrupt its own entries. The post-transfer balance check rejects tokens that fail silently. Fee-on-transfer and rebasing tokens are unsupported. Reentrancy follows checks-effects-interactions, with the nonce incremented before the transfer, and is tested with a reentrant token.

**Dust and fake tokens at forwarders.** Anyone can send junk tokens to a deposit address. Sweepers should allowlist tokens and simulate before sweeping. A sweep can only move value to the treasury.

**CREATE2 front-deployment.** Anyone can deploy a clone at a predicted address before the owner does. That is harmless, because the address commits to its args and there is no initializer. The SDK always recomputes addresses and checks them against the factory. It never trusts an address supplied by a relayer or an API.

**Wrong network or factory.** A deposit address derived for factory A on Nile means nothing on mainnet. The SDK's `assertFactoryDeployed` checks that the factory has code on the target network before deriving addresses.

**Upgrade risk.** This is the main residual trust; see [governance.md](governance.md). Mitigations: the immutable minimum delay, guardian veto, the public queue, and the execution window.

**Pause abuse.** A pause cannot freeze exits. Guardian pauses are bounded and rate-limited.

**Key rotation gap.** `ecrecover` checks a key, not Tron account permissions. Upgrading an account to multisig does not by itself revoke the key's permit authority. The owner must call `setSigner`, which *is* gated by account permissions.

**Token issuer powers.** USDT's issuer can freeze or blacklist addresses, and it has a dormant `basisPointsRate` fee switch. Both are out of scope. The accurate claim is "nothing in *these contracts* can freeze funds".

**Node trust (off-chain).** The SDK signs transactions built by a java-tron node. Before signing, it decodes the `raw_data_hex` protobuf, the bytes the signature commits to, and recomputes the txID from them. It then checks every field against the request:
- contract type and `type_url`
- owner, target, calldata and call value
- no TRC-10 value
- a single contract with `Permission_id` 0
- no memo
- a bounded `fee_limit` and expiration
- for deploys, the bytecode

The node's `raw_data` JSON is never trusted. A malicious node can still refuse service, lie about reads (balances, nonces, simulations), or withhold a broadcast until expiry. It cannot get a different call signed.

**Relayer economics.** The relayer pays energy before it is paid, and a permit can fail on-chain after passing simulation, for example when two relayers race on the same nonce. The reference relayer bounds this exposure:
- rolling spend limits (global, per owner, per API client)
- idempotent submits, so the same permit is never broadcast twice
- txids persisted before broadcast, so a crash cannot lose a paid transaction

Sponsor mode cannot run without a limit.

**Governance blind spots.** The timelock only helps people who notice a queued change. `gov watch` provides the alerting. Note that a role change cannot be vetoed by the guardian.

**TVM specifics.**
- A plain TRX transfer never runs `receive()`.
- A per-transaction CPU time limit (about 80 ms) can fail large batches that fit the energy budget.
- `SELFDESTRUCT` is restricted (none is used).
- The `fee_limit` cap is a chain parameter. The SDK clamps to it.

## Out of scope / known gaps

- TRC-10 tokens
- Fee-on-transfer and rebasing tokens
- An audit: **unaudited**, so do not use with significant funds until one is done
