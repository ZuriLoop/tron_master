/**
 * Which key signs.
 *
 * The default is a hex private key in the environment. It needs no account
 * anywhere and costs nothing, and it is the right choice for development, for
 * testnet, and for any host you are happy holding a key.
 *
 * `TPM_SIGNER=turnkey` moves signing to Turnkey instead, so the host holds
 * credentials that call a signer rather than the key itself — the difference
 * between a key you rotate and a key you re-provision. It is a paid service,
 * worth turning on when a key would otherwise sit on a long-lived machine with
 * real money behind it, and not before.
 *
 * Turnkey parses the Tron transaction it is asked to sign, so a policy can pin
 * the contract, the selector and the arguments. A stolen API credential then
 * cannot move funds anywhere the policy does not already allow. See
 * `examples/turnkey/src/policies.ts`.
 */
import { type TronSigner, parseTronAddress, tronSignerFromPrivateKey, turnkeyTronSigner } from "@tron-paymaster/sdk";
import type { Hex } from "viem";
import { UsageError } from "./errors.js";

export const SIGNER_ENV = {
  kind: "TPM_SIGNER",
  key: "TRON_PRIVATE_KEY",
  address: "TPM_SIGNER_ADDRESS",
  turnkeyPublicKey: "TURNKEY_API_PUBLIC_KEY",
  turnkeyPrivateKey: "TURNKEY_API_PRIVATE_KEY",
  turnkeyOrg: "TURNKEY_ORGANIZATION_ID",
  turnkeyBaseUrl: "TURNKEY_BASE_URL",
} as const;

type Env = Record<string, string | undefined>;

const need = (env: Env, name: string, why: string) => {
  const v = env[name];
  if (!v) throw new UsageError(`set ${name} (${why})`);
  return v;
};

/**
 * Builds the Turnkey client on first use, not at startup: the package is an
 * optional peer dependency, so an operator who signs with a private key never
 * has to install it.
 */
function turnkeySigner(env: Env): TronSigner {
  const address = need(env, SIGNER_ENV.address, "the Tron address of the Turnkey account that signs");
  const organizationId = need(env, SIGNER_ENV.turnkeyOrg, "your Turnkey organization id");
  const apiPublicKey = need(env, SIGNER_ENV.turnkeyPublicKey, "the Turnkey API key's public half");
  const apiPrivateKey = need(env, SIGNER_ENV.turnkeyPrivateKey, "the Turnkey API key's private half");
  const apiBaseUrl = env[SIGNER_ENV.turnkeyBaseUrl] ?? "https://api.turnkey.com";

  let delegate: Promise<TronSigner> | undefined;
  const build = async (): Promise<TronSigner> => {
    type TurnkeyCtor = new (c: { apiBaseUrl: string; apiPublicKey: string; apiPrivateKey: string; defaultOrganizationId: string }) => { apiClient(): unknown };
    let Turnkey: TurnkeyCtor;
    try {
      // A variable specifier on purpose: the package is an optional peer, so
      // this must not become a hard module resolution at build time.
      const spec = "@turnkey/sdk-server";
      ({ Turnkey } = (await import(spec)) as { Turnkey: TurnkeyCtor });
    } catch {
      throw new UsageError(`${SIGNER_ENV.kind}=turnkey needs @turnkey/sdk-server installed alongside the CLI`);
    }
    const client = new Turnkey({ apiBaseUrl, apiPublicKey, apiPrivateKey, defaultOrganizationId: organizationId });
    return turnkeyTronSigner({ api: client.apiClient() as never, address, organizationId });
  };

  // The address is configuration, so it is known without talking to anyone —
  // which keeps `signer()` synchronous for every caller.
  return {
    address: parseTronAddress(address),
    async signRawTransaction(tx) {
      delegate ??= build();
      return (await delegate).signRawTransaction!(tx);
    },
  };
}

function privateKeySigner(env: Env): TronSigner {
  const key = env[SIGNER_ENV.key];
  if (!key) {
    throw new UsageError(`set ${SIGNER_ENV.key} (hex private key) for commands that sign; keys are never read from flags`);
  }
  const hex = (key.startsWith("0x") ? key : `0x${key}`) as Hex;
  if (!/^0x[0-9a-fA-F]{64}$/.test(hex)) throw new UsageError(`${SIGNER_ENV.key} must be a 32-byte hex key`);
  return tronSignerFromPrivateKey(hex);
}

export function resolveSigner(env: Env = process.env): TronSigner {
  const kind = (env[SIGNER_ENV.kind] ?? "key").toLowerCase();
  if (kind === "key") return privateKeySigner(env);
  if (kind !== "turnkey") throw new UsageError(`${SIGNER_ENV.kind} must be "key" or "turnkey"`);
  // Ambiguity about which key moves money is not a warning-level problem.
  if (env[SIGNER_ENV.key]) {
    throw new UsageError(`${SIGNER_ENV.kind}=turnkey and ${SIGNER_ENV.key} are both set; unset one so it is unambiguous which key signs`);
  }
  return turnkeySigner(env);
}
