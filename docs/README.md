# Documentation

Start with [architecture](architecture.md) — what the pieces are and why there
are only two of them. Everything else answers a narrower question.

## Understanding it

| | |
|---|---|
| [architecture.md](architecture.md) | The deposit forwarder and the permit account, how an address exists before its contract, and where the fee comes from. |
| [permit-spec.md](permit-spec.md) | The exact TIP-712 permit: fields, domain, digest. What you need to produce a signature any implementation will accept. |
| [governance.md](governance.md) | Timelocked upgrades, the bounded pause, the fee ceiling — and which of them the owner's exit ignores. |
| [threat-model.md](threat-model.md) | What can go wrong, what is mitigated, and what is not. Read before holding anything of value. |
| [faq.md](faq.md) | Short answers, including why this is not ERC-4337 and what it costs. |

## Building on it

| | |
|---|---|
| [sdk.md](sdk.md) | `@tron-paymaster/sdk`: derive addresses, build and sign permits, talk to a relayer. |
| [cli.md](cli.md) | Deploy and govern a factory, derive addresses, move funds, claim fees. |
| [integrating-wallets.md](integrating-wallets.md) | Adding gasless sends to a wallet, including signers that only do EIP-712. |
| [integrating-custodial.md](integrating-custodial.md) | Per-user deposit addresses that sweep to a treasury without pre-funding anything. |
| [reference.md](reference.md) | Contract interfaces, errors and events. |

## Not here

The relayer's HTTP protocol is specified by the types in
[`sdk/src/relayerClient.ts`](../sdk/src/relayerClient.ts) — quote, submit,
status — which is also the client this repository ships, so the types are the
specification rather than a description of one. No relayer implementation is
included.

The client application lives in
[tronmaster-client](https://github.com/ZuriLoop/tronmaster-client).
