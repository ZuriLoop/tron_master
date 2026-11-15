# Security

## Status: unaudited

These contracts have not been through a third-party audit, and there is no
mainnet deployment. Treat anything here as experimental.

## Scope

- `contracts/src/` — the protocol
- `sdk/src/` — address derivation, permits, signing, the relayer client
- `cli/src/` — deployment, governance, and the commands that move funds

What to look at hardest, in the order a mistake would hurt:

- **Address derivation** (`contracts/src/PaymasterFactory.sol`,
  `sdk/src/create2.ts`). The SDK and the factory must agree exactly. An address
  the SDK predicts but the factory would never deploy to is funds nobody can
  reach, and nothing on chain will warn anyone first.
- **Permit verification** (`contracts/src/PermitAccount.sol`,
  `sdk/src/permit.ts`). A digest the contract accepts that does not commit to
  every field a signer was shown, or a signature replayable across accounts,
  chains or nonces, is the worst outcome in this repository.
- **Fee accounting.** A relayer is repaid from the account's own balance. A path
  that charges more than the `maxFee` the owner signed, or that charges without
  the transfer happening, is a direct loss.
- **The owner's exit** (`withdraw`). It must work when the protocol is paused,
  when the signer key has been rotated, and when no relayer exists. Any way to
  block it is a way to trap funds.
- **Governance bounds.** The constructor fixes the fee ceiling, the upgrade
  delay range and the maximum pause. A route past any of those — including via
  an upgrade — defeats the guarantees the rest of this rests on.

## Reporting

Report privately through GitHub's security advisories on this repository
("Security" → "Report a vulnerability"), not a public issue.

Include what an attacker gains and the smallest reproduction you have. A
proof of concept against Nile testnet is ideal and costs nothing.
