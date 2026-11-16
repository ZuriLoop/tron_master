---
title: "TypeScript SDK"
description: "@tron-paymaster/sdk: addresses, permits, signers, and clients."
icon: "code"
---

```sh
npm install @tron-paymaster/sdk viem
```

The package ships ESM and CJS with types, and runs on Node 20+, browsers, Workers, Bun and Deno. It has no Node built-ins and no TronWeb. `viem` is its only dependency, declared as a peer. Addresses are handled internally as 20-byte `0x` hex (`TronAddress`). Every input accepts base58 `T…`, `41…` hex or `0x…` hex.

## Addresses

```ts
import { parseTronAddress, toBase58, toTronHex } from "@tron-paymaster/sdk";

const a = parseTronAddress("TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"); // 0xa614…d13c, checksum verified
toBase58(a);   // "TR7N…Lj6t"
toTronHex(a);  // "41a614…d13c"
```

## Client

```ts
import { createPaymasterClient, tronNile, tronSignerFromPrivateKey } from "@tron-paymaster/sdk";

const client = createPaymasterClient({
  chain: tronNile,                        // or tronMainnet / localChain(url)
  factory: "T…factory",
  apiKey: process.env.TRON_API_KEY,       // TronGrid, optional
  signer: tronSignerFromPrivateKey(key),  // pays energy for writes
});

await client.getFactoryInfo();            // config + governance state (live)
```

Every write goes through `client.send(to, data)`:
1. simulate it with `triggerconstantcontract`
2. derive `fee_limit` from the simulated energy × 1.3, clamped to the chain maximum
3. have the node build the transaction
4. verify the txID and the call fields, then sign locally
5. broadcast, then wait until the transaction is executed (inclusion alone is not success)

## Custodial: deposit addresses and sweeps

```ts
import { deriveDepositSalt, getForwarderAddress } from "@tron-paymaster/sdk";

const salt = await deriveDepositSalt(process.env.DEPOSIT_SECRET!, `user:${userId}`);
const address = await client.predictForwarder(treasury, salt);          // cross-checked with the factory

// Offline, e.g. deriving 100k addresses: cache forwarderRouter once.
const { forwarderRouter } = await client.getDeployment();
const addr = getForwarderAddress({ factory: client.factory, forwarderRouter, treasury, salt });

// Sweep (deploys on first use). The signer pays energy.
await client.sweep({ treasury, salt, token: USDT });
await client.sweepMany(items);
```

## Non-custodial: permits

Through a relayer:

```ts
import { createRelayerClient, fromPrivateKey } from "@tron-paymaster/sdk";

const relayer = createRelayerClient({ url: ["https://relayer-a.example", "https://relayer-b.example"] });
const q = await relayer.quote({ owner, token: USDT, to, value: 10_000_000n });

// Always check the quote against chain state yourself:
const state = await client.getAccountState(owner);
if (q.account !== state.address || BigInt(q.nonce) !== state.nonce) throw new Error("bad quote");

const sig = await client.signPermit(fromPrivateKey(ownerKey), q.unsignedPermit, state.address, state.signer);
// A stable idempotencyKey makes retries safe: the relayer never broadcasts twice.
const sub = await relayer.submit({ permit: q.unsignedPermit, signature: sig, quoteId: q.quoteId, idempotencyKey: `${state.address}:${state.nonce}` });
const st = await relayer.waitForPermit(sub.id); // INCLUDED | FAILED
if (st.status !== "INCLUDED") throw new Error(`transfer ${st.status}: ${st.error}`);
```

Self-relay (your signer pays energy):

```ts
const prep = await client.preparePermit({ owner, token: USDT, to, value, relayerFee: 0n });
const sig = await client.signPermit(ownerSigner, prep.permit, prep.account, prep.signer);
await client.submitPermit({ permit: prep.permit, signature: sig, relayerFee: 0n });
// uses deployAndPermit automatically when the account has no code yet
```

Low-level:

```ts
import { buildPermit, getPermitDigest, signPermit, encodePermitTransfer } from "@tron-paymaster/sdk";

const permit = buildPermit({ token, owner, to, value, maxFee, relayer, nonce }); // 180 s default
const digest = getPermitDigest(permit, { account, chainId });  // only accepts buildPermit output
const sig = await signPermit(signer, permit, { account, chainId }); // verifies recovery before returning
const data = encodePermitTransfer({ permit, signature: sig, relayerFee, feeRecipient });
```

`getPermitDigest` rejects plain objects and wallet JSON at runtime. This makes the "hash the base58 JSON" bug impossible.

## Signers

| Adapter | Use |
|---|---|
| `fromPrivateKey(hex)`, `fromViemAccount(account)` | local keys, mnemonics, HD |
| `fromDigestSigner({ address, sign })` | KMS / HSM / MPC that signs a 32-byte digest |
| `fromInjectedTron(window.tronWeb)` | browser wallets (`trx._signTypedData`) |

Every adapter normalizes v to 27/28, rejects high-s, and checks that the signature recovers to the expected signer.

For Tron *transactions* (paying energy), use `tronSignerFromPrivateKey`, or implement `TronSigner` (`address` and `signTransactionId(txId)`) for a remote signer.

Every transaction is checked before the signer is called. `verifyTransaction(tx, expected)` decodes `raw_data_hex`, the protobuf the signature commits to, using `decodeTransactionRaw`. It rejects any difference from the intended call: contract, calldata, value, owner, extra contracts, TRC-10 fields, permission id, memo, `fee_limit`, or an expiration more than `TronRpc({ maxTxExpiryMs })` ahead (default 1 h). The node's `raw_data` JSON is never used. `PaymasterClient.prepare(to, data)` returns a verified, signed transaction without broadcasting it, so callers can persist the txid first.

## Owner operations

```ts
const owner = createPaymasterClient({ chain, factory, signer: tronSignerFromPrivateKey(ownerKey) });
await owner.withdraw({ token: USDT, to, amount });   // never paused; the owner needs TRX/energy for this tx
await owner.setSigner({ signer: newKeyAddress });
await owner.invalidateNonces({ newNonce: 10n });
```

## Relayer fee claims

```ts
await client.claimMany({ accounts, token: USDT });   // pays the signer's own accrual
```

## Governance

`client.gov.queueUpgrade(Kind.Account, impl)`, `executeUpgrade`, `cancelUpgrade`, `pause`, `unpause`, `setProtocolFee`, `queueRoles`, `cancelRoles`, `executeRoles`. The signer must be the admin or the guardian.

## Errors

- `TronRpcError` carries the node's response. Reverts are decoded to the contract's custom error name, e.g. `call reverted: NotAuthorized`.
- `RelayerError` carries the HTTP status. 4xx errors are not retried across relayers.
