import {
  type Hex,
  type PaymasterClient,
  type TronChain,
  type TronSigner,
  TronRpc,
  chains,
  createPaymasterClient,
  deriveDepositSalt,
  formatUnits,
  localChain,
  toBase58,
} from "@tron-paymaster/sdk";

export type Flags = Record<string, string | boolean | undefined>;

import { UsageError } from "./errors.js";
import { resolveSigner } from "./signers.js";

export { UsageError };

export interface Context {
  flags: Flags;
  chain: TronChain;
  rpc: TronRpc;
  json: boolean;
  out(human: string, data?: unknown): void;
  str(name: string, required?: boolean): string | undefined;
  need(name: string): string;
  bool(name: string): boolean;
  signer(): TronSigner;
  client(opts?: { signer?: boolean }): PaymasterClient;
  /** Refuses state-changing mainnet actions unless --yes. */
  confirmWrite(what: string): void;
  salt(): Promise<Hex>;
  fmt(addr: string): string;
}

const ENV = {
  key: "TRON_PRIVATE_KEY",
  apiKey: "TRON_API_KEY",
  factory: "TPM_FACTORY",
  secret: "TPM_DEPOSIT_SECRET",
  network: "TPM_NETWORK",
  /** Longest tx expiration accepted from the node, in seconds (default 3600). */
  maxTxExpiry: "TPM_MAX_TX_EXPIRY_SECONDS",
} as const;
export { ENV };

export function resolveChain(flags: Flags): TronChain {
  const net = String(flags.network ?? process.env[ENV.network] ?? "nile");
  const rpc = flags.rpc ? String(flags.rpc) : undefined;
  let chain: TronChain;
  if (net === "mainnet" || net === "nile") chain = { ...chains[net] };
  else if (net === "local") chain = localChain(rpc);
  else throw new UsageError(`unknown network "${net}" (mainnet | nile | local)`);
  if (rpc) chain.rpcUrl = rpc;
  return chain;
}

export function makeContext(flags: Flags): Context {
  const chain = resolveChain(flags);
  const expiry = process.env[ENV.maxTxExpiry];
  const rpc = new TronRpc({ url: chain.rpcUrl, apiKey: process.env[ENV.apiKey], maxTxExpiryMs: expiry ? Number(expiry) * 1000 : undefined });
  const json = Boolean(flags.json);
  let signer: TronSigner | undefined;

  const ctx: Context = {
    flags,
    chain,
    rpc,
    json,
    out(human, data) {
      if (json) process.stdout.write(`${JSON.stringify(data ?? { message: human }, jsonReplacer, 2)}\n`);
      else process.stdout.write(`${human}\n`);
    },
    str(name, required) {
      const v = flags[name];
      if (v === undefined || v === true || v === "") {
        if (required) throw new UsageError(`--${name} is required`);
        return undefined;
      }
      return String(v);
    },
    need(name) {
      return ctx.str(name, true)!;
    },
    bool(name) {
      return flags[name] === true || flags[name] === "true";
    },
    signer() {
      signer ??= resolveSigner();
      return signer;
    },
    client(opts = {}) {
      const factory = ctx.str("factory") ?? process.env[ENV.factory] ?? chain.deployments[0]?.factory;
      if (!factory) throw new UsageError(`--factory (or ${ENV.factory}) is required on ${chain.name}`);
      return createPaymasterClient({
        chain,
        rpc,
        factory,
        signer: opts.signer ? ctx.signer() : undefined,
      });
    },
    confirmWrite(what) {
      if (chain.name === "mainnet" && !ctx.bool("yes")) {
        throw new UsageError(`refusing to ${what} on MAINNET without --yes`);
      }
    },
    async salt() {
      const s = ctx.str("salt");
      if (s) {
        if (!/^0x[0-9a-fA-F]{64}$/.test(s)) throw new UsageError("--salt must be 32-byte hex");
        return s as Hex;
      }
      const id = ctx.str("id");
      if (!id) throw new UsageError("pass --salt 0x… or --id <deposit id> (with TPM_DEPOSIT_SECRET)");
      return deriveDepositSalt(depositSecret(), id);
    },
    fmt(addr) {
      return toBase58(addr);
    },
  };
  return ctx;
}

export function depositSecret(): string {
  const s = process.env[ENV.secret];
  if (!s || s.length < 32) throw new UsageError(`set ${ENV.secret} (>= 32 chars) to derive deposit salts from ids`);
  return s;
}

export function jsonReplacer(_k: string, v: unknown) {
  return typeof v === "bigint" ? v.toString() : v;
}

export function fmtAmount(v: bigint, decimals: number, symbol: string) {
  return `${formatUnits(v, decimals)} ${symbol}`;
}

export function explorerTx(chain: TronChain, txid: string) {
  return chain.explorerUrl ? `${chain.explorerUrl}/#/transaction/${txid}` : txid;
}
