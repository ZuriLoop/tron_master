---
title: "CLI"
description: "The tron-paymaster command: addresses, sweeps, transfers, the reference relayer, and gov watch."
icon: "terminal"
---

```sh
npm install -g @tron-paymaster/cli
tron-paymaster --help
```

## Configuration

| Env / flag | Meaning |
|---|---|
| `--network mainnet\|nile\|local` / `TPM_NETWORK` | default `nile` |
| `--rpc <url>` | node URL override (local default `http://127.0.0.1:9090`) |
| `TRON_API_KEY` | TronGrid API key |
| `--factory <addr>` / `TPM_FACTORY` | the PaymasterFactory |
| `TRON_PRIVATE_KEY` | signing key (hex). **Never accepted as a flag** |
| `TPM_DEPOSIT_SECRET` | secret for `--id` → salt derivation (>= 32 chars) |
| `--json` | machine-readable output |
| `--yes` | required for every state-changing command on mainnet |

## Setup

```sh
tron-paymaster keygen
tron-paymaster deploy-factory --admin T…admin --guardian T…guardian \
  --fee-token T…usdt --fee-recipient T…fees --max-bps 50 --max-cap 1 --bps 10 --cap 0.25 \
  --upgrade-delay 3d --pause-duration 7d
export TPM_FACTORY=T…
tron-paymaster info
```

`deploy-factory` validates the config locally (mirroring the constructor) before paying for a deploy. It sets `consume_user_resource_percent = 100`, so callers pay their own energy. Expect around 5.3M energy, which is around 530 TRX at 100 sun per energy. That figure was measured on a local node; check mainnet energy prices before deploying.

## Resources (Stake 2.0)

```sh
tron-paymaster resources                             # limits, usage, per-TRX yield
tron-paymaster stake --amount 300 --energy           # or --bandwidth
tron-paymaster unstake --amount 300 --energy         # starts the 14-day withdrawal
tron-paymaster withdraw-unfrozen                     # claim unstaked TRX past the wait
```

Staking and unstaking act on the signer's own account and go through the same
byte-level transaction verification as every other write.

## Custodial

```sh
tron-paymaster deposit-address --treasury T…treasury --id user-42
tron-paymaster deposit-addresses --treasury T…treasury --count 1000 --prefix user- --json > addresses.json
tron-paymaster sweep --treasury T…treasury --id user-42              # USDT (default token)
tron-paymaster sweep --treasury T…treasury --id user-42 --trx
tron-paymaster sweep-many --file sweeps.json                         # [{treasury, id|salt, token?, sweeper?}]
```

`deposit-addresses` derives addresses offline, after cross-checking the first one against the factory.

## Non-custodial

```sh
tron-paymaster account --owner T…owner
tron-paymaster transfer --to T…recipient --amount 10 --relayer https://relayer.example
tron-paymaster transfer --to T…recipient --amount 10 --self          # your key pays energy
tron-paymaster withdraw --to T…me --amount 5                         # owner exit
tron-paymaster set-signer --signer T…newkey
tron-paymaster invalidate-nonces --nonce 100
tron-paymaster fees --amount 100
tron-paymaster claim --accounts T…a,T…b                              # relayer fee claims
```

`transfer --relayer` cross-checks the relayer's quote against chain state before signing: the account address, the nonce, and the permit's amount, recipient and token.

## Governance

```sh
tron-paymaster gov status
tron-paymaster gov queue-upgrade --kind account --impl T…newImpl
tron-paymaster gov execute-upgrade --kind account
tron-paymaster gov cancel-upgrade --kind account                     # admin or guardian
tron-paymaster gov pause | gov unpause
tron-paymaster gov set-fee --bps 5 --cap 0.2
tron-paymaster gov queue-roles --admin T… --guardian T…
tron-paymaster gov execute-roles                                     # run as the incoming admin
tron-paymaster gov watch --interval 60 --webhook https://alerts.example/tpm   # alert on governance changes
tron-paymaster gov watch --once                                       # for cron/CI: exit 3 if an upgrade or role change is queued
```

## Exit codes

`0` success · `1` runtime or chain error · `2` usage error or refused (e.g. mainnet without `--yes`) · `3` `gov watch --once` found a queued upgrade or role change.

## Environment

| Variable | Used by |
|---|---|
| `TRON_PRIVATE_KEY` | every write, when signing with a local key |
| `TPM_SIGNER` | `key` (default) or `turnkey` — see [signing without a local key](#signing-without-a-local-key) |
| `TPM_SIGNER_ADDRESS`, `TURNKEY_ORGANIZATION_ID`, `TURNKEY_API_PUBLIC_KEY`, `TURNKEY_API_PRIVATE_KEY` | `TPM_SIGNER=turnkey` |
| `TRON_API_KEY` | TronGrid rate limits |
| `TPM_FACTORY`, `TPM_NETWORK`, `TPM_DEPOSIT_SECRET` | defaults for `--factory`, `--network`, deposit salts |
| `TPM_WEBHOOK_SECRET` | `gov watch --webhook` signing (≥ 32 chars) |
| `TPM_MAX_TX_EXPIRY_SECONDS` | longest node-issued tx expiration accepted before signing (default 3600) |

## Signing without a local key

**A local key is the default and costs nothing.** `TRON_PRIVATE_KEY` needs no account anywhere, and it is the
right choice for development, for testnet, and for any host you are happy holding a key. Nothing below is
required.

A hex key in the environment is fine for a laptop and less good for a host that runs for months: it ends up in a file, a process listing, or a backup of a machine somebody has to patch. `TPM_SIGNER=turnkey` moves signing to Turnkey, so the host holds credentials that *call* a signer rather than the key itself. It is a paid service, so it is worth turning on when a key is sitting on a long-lived machine with real money behind it — not before.

```sh
export TPM_SIGNER=turnkey
export TPM_SIGNER_ADDRESS=T…            # the Tron address of the Turnkey account
export TURNKEY_ORGANIZATION_ID=…
export TURNKEY_API_PUBLIC_KEY=…
export TURNKEY_API_PRIVATE_KEY=…
tron-paymaster gov queue-upgrade --kind account --impl T… --network mainnet --yes
```

Every signing command works this way. `@turnkey/sdk-server` is an optional peer dependency, loaded only when this is switched on, so an operator signing with a key never installs it.

Turnkey is sent the transaction protobuf, not a description of it, so a policy can pin the contract, the selector and the arguments — a stolen API credential then cannot move funds anywhere the policy does not already allow. Setting both `TPM_SIGNER=turnkey` and `TRON_PRIVATE_KEY` is an error rather than a precedence rule: which key moves money should never be ambiguous.
