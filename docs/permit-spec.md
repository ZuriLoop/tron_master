---
title: "Permit specification"
description: "The TIP-712 typed data a PermitAccount owner signs."
icon: "file-signature"
---

A permit is an owner's signed instruction for a PermitAccount to transfer `value` of `token` to `to`.

## Domain

```
EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)
name              = "TronPaymaster"
version           = "1"
chainId           = block.chainid & 0xffffffff
verifyingContract = the PermitAccount (20-byte address)
```

TIP-712 differs from EIP-712 only in the chain id, which is masked to its low 4 bytes. That value is the last 4 bytes of the genesis block id.

| Network | chainId |
|---|---|
| Mainnet | 728126428 (`0x2b6653dc`) |
| Nile | 3448148188 (`0xcd8690dc`) |

The SDK derives it with `TronRpc.getChainId()`, and the end-to-end test checks it against the contract's `eip712Domain()`.

## Type

```
PermitTransfer(address token,address owner,address to,uint256 value,uint256 maxFee,address relayer,uint256 deadline,uint256 nonce)
```

| Field | Meaning |
|---|---|
| token | TRC-20 to move |
| owner | must equal the account's owner (redundant with `verifyingContract`, but explicit) |
| to | recipient; not zero, not the account |
| value | exact amount the recipient receives (> 0) |
| maxFee | upper bound on relayer fee + protocol fee, in `token` units |
| relayer | the only allowed fee recipient; zero = any |
| deadline | unix seconds; valid while `block.timestamp <= deadline` |
| nonce | must equal the account's current nonce |

Addresses are hashed as 20-byte values. A wallet that signs typed data with base58 addresses must convert them back before hashing. The SDK verifies every signature locally before submitting, so a wallet that gets this wrong fails off-chain.

**Digest:** `keccak256(0x1901 ‖ domainSeparator ‖ keccak256(abi.encode(TYPEHASH, token, owner, to, value, maxFee, relayer, deadline, nonce)))`.

## Signature

The contract takes `(r, vs)`, the EIP-2098 compact form, where `vs = s | (yParity << 255)`. `s` must be in the lower half of the curve order. The SDK's `normalizeSignature` accepts 65-byte signatures with v ∈ {0, 1, 27, 28}, or `{r, s, v}` objects. It rejects high-s outright instead of flipping it: a signer producing high-s is misbehaving.

The expected signer is `account.signer()`, which is the owner unless it has been rotated with `setSigner`.

## Replay protection

| Replay | Prevented by |
|---|---|
| Same permit twice | sequential nonce |
| Another account (same owner, other index) | `verifyingContract` |
| Another network | `chainId` |
| Another factory | different account address, so a different `verifyingContract` |
| Stale permit | `deadline`, `invalidateNonces` |
| Front-running for the fee | `relayer` binding |

## SDK deadline policy

`buildPermit` defaults to 180 seconds. It warns above 10 minutes and refuses more than 24 hours unless `allowLongDeadline` is set. Permits have no on-chain allowance that revocation tools could see, so short deadlines are the main defense against phishing.

## Test vectors

`sdk/vectors/vectors.json` holds the vectors: addresses, init code, CREATE2 predictions (both prefixes), digests and signatures from a published test key. They are checked by the SDK (vitest) and the contracts (Foundry, `Vectors.t.sol`).
