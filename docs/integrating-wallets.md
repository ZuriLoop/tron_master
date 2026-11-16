---
title: "Wallets"
description: "Gasless USDT sends from accounts the user controls."
icon: "wallet"
---

The guide is for self-custodial and embedded wallets whose users hold USDT but no TRX.

## The user's gasless address

Each user key has a **PermitAccount**: a deterministic address derived from the owner key and an index (normally 0). The user receives USDT **at the PermitAccount**, not at their key's own address. Sends from it are signed permits that any relayer can submit.

```ts
const client = createPaymasterClient({ chain: tronMainnet, factory });
const state = await client.getAccountState(userAddress);   // { address, deployed, nonce, signer }
// Show state.address as the user's "receive" address for gasless tokens.
```

The account is deployed by the first send, inside the same transaction (`deployAndPermit`). Receiving needs nothing.

UX notes:
- The user's normal Tron address and their gasless address differ. Label them clearly, e.g. "USDT (gasless)".
- To move existing funds in, the user sends a normal transfer from their key address. That one transfer needs TRX or energy. Alternatively, have counterparties pay to the gasless address directly.

## Sending

```ts
const relayer = createRelayerClient({ url: [primary, fallback] });
const q = await relayer.quote({ owner: userAddress, token: USDT, to, value });

// 1. Verify the quote against chain state. Never trust it blindly.
if (q.account !== state.address || BigInt(q.nonce) !== state.nonce) throw new Error("bad quote");

// 2. Show the user what they sign: amount, recipient, max fee, expiry.
//    The permit is short-lived (180 s default) and single-use.

// 3. Sign.
const sig = await client.signPermit(signer, q.unsignedPermit, state.address, state.signer);

// 4. Submit to the same relayer that quoted.
// A stable idempotencyKey makes retries safe: the relayer never broadcasts twice.
const sub = await relayer.submit({ permit: q.unsignedPermit, signature: sig, quoteId: q.quoteId, idempotencyKey: `${state.address}:${state.nonce}` });
const st = await relayer.waitForPermit(sub.id); // INCLUDED | FAILED
if (st.status !== "INCLUDED") throw new Error(`transfer ${st.status}: ${st.error}`);
```

### EVM wallets (MetaMask, Rabby, Coinbase Wallet…)

An EVM wallet can send gasless Tron USDT without ever building a Tron
transaction: Tron and Ethereum share secp256k1, so the wallet's key is a valid
Tron owner key, and a permit is EIP-712 typed data, so `eth_signTypedData_v4`
yields exactly the signature the Tron contract verifies (byte-identical to a
local-key signature — asserted in the SDK tests). A relayer does everything
Tron-side.

The wallet does have to *recognize the network*, though. MetaMask validates
`domain.chainId` against the active chain and rejects a mismatch before it
even prompts (`Provided chainId … must match the active chainId`). TronGrid
exposes an Ethereum-compatible JSON-RPC whose `eth_chainId` equals the TIP-712
chain id, so Tron can be added as an ordinary custom network — pass
`TRON_EVM_NETWORKS[...]` and the signer adds and switches to it for you:

```ts
import { TRON_EVM_NETWORKS, fromEip1193, signPermit } from "@tron-paymaster/sdk";

const [account] = await window.ethereum.request({ method: "eth_requestAccounts" });
// `account` is also the owner's Tron address (same 20 bytes).
const signer = fromEip1193(window.ethereum, account, TRON_EVM_NETWORKS.mainnet); // or .nile
const sig = await signPermit(signer, permit, { account: state.address, chainId }, { expectedSigner: state.signer });
```

One honest consequence: an EVM wallet cannot sign Tron *transactions*, so a
user of one has the relayer path only. Withdrawing without any relayer, and
`invalidateNonces` / `setSigner`, all need a Tron transaction — reachable by
importing the same key into a Tron wallet. Tell users that before they fund
an account, not after.

Two things to design for: show the decoded permit yourself (the wallet renders
raw typed-data fields), and label the Tron account clearly — it is a different
address from the user's Ethereum account, and it is where they must receive
USDT. A runnable app is in [tronmaster-client](https://github.com/ZuriLoop/tronmaster-client), which connects MetaMask, TronLink or a Turnkey passkey wallet against these contracts.

### Signers

| Wallet type | Adapter |
|---|---|
| Local or HD keys | `fromPrivateKey`, `fromViemAccount` |
| MPC or HSM signing 32-byte digests | `fromDigestSigner({ address, sign })` |
| MPC with EIP-712 support | implement `signTypedData` (see [`examples/turnkey`](https://github.com/ZuriLoop/tron-paymaster/tree/main/examples/turnkey)) |
| Browser TronLink-style | `fromInjectedTron(window.tronWeb)` |

Every adapter is verified locally: the signature must recover to the account's signer before submission. If a wallet encodes typed data wrongly (e.g. hashes base58 addresses), the error appears in your app, not on-chain.

### What to display before signing

A permit has no on-chain allowance, so revocation tools will not show it. Show the decoded fields:
- token, amount and recipient
- `maxFee` (relayer + protocol)
- relayer
- expiry

`describePermit` in the Turnkey example is a template.

## Fees

- **Relayer fee.** Quoted per transfer, it covers the relayer's energy. The first send costs more, because it deploys the account. So does sending to an address that has never held the token.
- **Protocol fee.** `min(value × bps, cap)` in the factory's fee token. Read it with `client.protocolFee`.
- Both come out of the account's balance; the recipient receives exactly `value`. Make sure `available >= value + fees`. Relayers refuse to quote otherwise.

## Exits and key safety

| Action | How |
|---|---|
| Withdraw (direct) | `client.withdraw({ token, to, amount })` from the owner key. This is an ordinary transaction, so the owner needs a little TRX or energy. It is never paused |
| Withdraw (gasless) | a normal permit to an address the user controls |
| Cancel outstanding permits | `invalidateNonces(n)` |
| Key moved to multisig | `setSigner(newKey)`. `ecrecover` checks a key, not Tron account permissions, so rotate explicitly |

## Choosing relayers

Relaying is permissionless. Configure several URLs: the client falls back on network and 5xx errors, but never on 4xx (a rejected permit). You can run the reference relayer yourself (`tron-paymaster relay serve`), or self-submit with any funded key (`client.submitPermit`).
