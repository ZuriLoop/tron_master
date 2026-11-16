---
title: "FAQ"
description: "Short answers to common questions."
icon: "circle-question"
---

**Is this ERC-4337?**
No. It is a paymaster in the 4337 *sense*: sponsored gas, fees paid in a token. Tron has no EntryPoint, bundlers or UserOps. Accounts verify a TIP-712 permit, and anyone can submit it.

**Why not just delegate or rent energy to each address?**
- Delegation needs the address activated first, which takes TRX.
- Each rental is per address, so the bookkeeping grows with your user count.
- Delegation lags behind the order.

With TronPaymaster, the party that moves funds pays from one account it already funds. Deposit addresses never need TRX.

**Can the deployer, admin or relayer steal funds?**
- No role can move funds directly.
- A relayer can only execute what the owner signed.
- A sweeper can only send forwarder funds to the treasury in the address.
- The admin can upgrade implementations, but only after a public timelock of at least 48 hours, with a guardian veto, during which owners can withdraw. That is the residual trust. See [governance.md](governance.md).

**Can funds be frozen?**
Not by these contracts. A pause blocks permits and sweeps for a bounded time, never withdrawals. Token issuers keep their own powers; USDT can freeze addresses.

**Do addresses change after an upgrade?**
No. Clones point at an immutable router, which forwards to the current implementation.

**What does it cost?**
Measured on Nile with real USDT:
- first sweep 76.6k energy, later sweeps 24.3k
- first gasless send 162k, later sends 51k

Mainnet USDT carries a dynamic-energy penalty, so mainnet costs are higher. Renting energy cuts the cost well below the burn price.

**Who pays energy?**
The caller: the sweeper or the relayer. The factory is deployed with `consume_user_resource_percent = 100`, so the deployer never subsidizes calls. This is verified on receipts.

**Does the user need TRX at all?**
For permit sends, no. For a *direct* owner withdrawal, yes: it is the owner's own transaction. An owner with no TRX can exit gaslessly by signing a permit to themselves.

**Which tokens work?**
Standard TRC-20s, including Tron USDT, whose `transfer` returns `false` on success. Fee-on-transfer, rebasing and TRC-10 tokens are not supported.

**Is a relayer required?**
No. Anyone can submit a signed permit (`client.submitPermit`), and anyone can run a relayer — the HTTP protocol one must speak is the types in [`sdk/src/relayerClient.ts`](../sdk/src/relayerClient.ts).

**How is this verified?**
- **Foundry:** unit tests, fuzzing, and stateful invariants for fee accounting, governance and forwarder custody.
- **Test vectors:** shared between the SDK and the contracts.
- **TVM end-to-end:** on a local java-tron node, in CI.
- **Nile end-to-end:** with the real TetherToken, nightly in CI.

The code is **unaudited**. An audit is planned before mainnet use with significant funds.
