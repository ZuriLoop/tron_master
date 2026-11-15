# TronMaster

Move Tron USDT without holding TRX.

A Tron address derived from your own key can receive tokens and spend them
immediately, with someone else paying the network cost and being repaid out of
the transfer. No TRX, no account activation, no custodian.

## The idea

Tron charges the sender energy, paid in TRX. That is the whole onboarding
problem: a person who has been sent USDT and nothing else cannot move it.

An account here is a contract whose address is derived from its owner's public
key and a factory address, with CREATE2:

- **The address exists before the contract does.** It receives tokens with no
  code deployed, and deploys itself on first spend. Opening an account costs
  nothing and needs no transaction.
- **It obeys one signature.** Spending is authorised by a TIP-712 permit naming
  the token, amount, recipient, a maximum fee and a deadline. Whoever submits it
  pays the energy and is repaid the fee **from the transfer itself**, in the
  token being moved.
- **Submission is permissionless.** The permit names a relayer or allows any.
  There is no registry, no allowlist and no privileged submitter.
- **The owner can always leave.** `withdraw` is callable by the owner directly,
  pays its own energy, and is not affected by any pause.

TIP-712 is EIP-712 with the chain id masked to four bytes, so an Ethereum
wallet's existing typed-data signing produces exactly the digest these
contracts verify — which is why an EVM wallet, or a signer like Turnkey, works
on Tron without any Tron-specific signing code.

## What's here

| | |
|---|---|
| [`contracts/`](contracts) | The protocol: `PaymasterFactory`, `PermitAccount`, `DepositForwarder`, `ImplementationRouter`. Foundry tests, fuzz and invariants. |
| [`sdk/`](sdk) | Address derivation, permit construction and signing, the relayer client. No dependencies but `viem`. |
| [`cli/`](cli) | Deploy a factory, govern it, derive addresses, move funds, claim fees. |

## Build and test

```sh
git clone --recurse-submodules https://github.com/ZuriLoop/tron_master
pnpm install
pnpm --filter @tron-paymaster/sdk build
pnpm -r test          # 100 Foundry tests, plus the SDK and CLI suites
```

The Foundry suite runs on EVM: the sources are identical to the Tron build, and
the only difference — the CREATE2 prefix, `0x41` on TVM — is isolated behind one
overridable function. The production artifact is built with tron-solc.

## Reproducing the deployed bytecode

The build is pinned so anyone can rebuild a deployed factory byte for byte and
check it against the chain:

```
solc        0.8.26 (tron-solc for the production artifact)
evm_version cancun
optimizer   on, 10000 runs
via_ir      false
bytecode_hash none
```

`contracts/script/compile-tron.mjs` produces the artifact; `cli/src/deploy.ts`
encodes the constructor and `validateFactoryConfig` states every constraint the
constructor enforces — fee ceilings, the upgrade delay range, the maximum pause,
and that admin and guardian cannot be the same address.

## Governance

Upgrades are timelocked and the delay is fixed at deployment, inside a range the
constructor enforces. A guardian can pause, bounded by a maximum duration also
fixed at deployment, and **withdrawals are never pausable**. The fee has a
ceiling set in the constructor that no later change can exceed.

`tron-paymaster gov status` reads all of it from the chain, and `gov watch`
alerts on anything queued, executed or cancelled. A timelock only protects
people who are watching.

## Status

**Unaudited.** Nile testnet only; there is no mainnet deployment. Do not put
money you care about through it.

## Not in this repository

The client application and its React hooks live in
[tronmaster-client](https://github.com/ZuriLoop/tronmaster-client).

A relayer implementation is not included. The HTTP protocol one must speak is
specified by the types in [`sdk/src/relayerClient.ts`](sdk/src/relayerClient.ts)
— quote, submit, status — and that file is also the client this repo ships, so
the types are the specification rather than a description of one.

## Licence

Apache-2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
