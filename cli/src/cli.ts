import { readFileSync } from "node:fs";
import { parseArgs } from "node:util";
import {
  ZERO_ADDRESS,
  type Hex,
  Kind,
  type SweepItem,
  createRelayerClient,
  deriveDepositSalt,
  formatUnits,
  fromPrivateKey,
  getForwarderAddress,
  freezeBalance,
  getTokenInfo,
  parseTronAddress,
  parseUnits,
  toBase58,
  type StakeResource,
  unfreezeBalance,
  withdrawExpireUnfreeze,
} from "@tron-paymaster/sdk";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { type Context, ENV, type Flags, UsageError, depositSecret, explorerTx, fmtAmount, makeContext } from "./context.js";
import { deployFactory } from "./deploy.js";
import { type GovernanceAlert, createGovernanceWatcher } from "./watcher.js";
import { createWebhookDispatcher } from "./webhooks.js";

const VERSION = "0.1.0";

const HELP = `tron-paymaster ${VERSION} — Tron gas sponsorship

Usage: tron-paymaster <command> [options]

Global options
  --network mainnet|nile|local   (default: nile, env ${ENV.network})
  --rpc <url>                    override the node URL (env ${ENV.apiKey} for TronGrid)
  --factory <address>            PaymasterFactory (env ${ENV.factory})
  --json                         machine-readable output
  --yes                          required for state-changing commands on mainnet

Signing key: ${ENV.key} (hex). Deposit-id salts: ${ENV.secret}. Keys are never accepted as flags.
  TPM_SIGNER=turnkey signs through Turnkey instead, so a long-running host keeps no key at all
  (TPM_SIGNER_ADDRESS, TURNKEY_ORGANIZATION_ID, TURNKEY_API_PUBLIC_KEY,
  TURNKEY_API_PRIVATE_KEY, optional TURNKEY_BASE_URL).

Resources (the signer's own account)
  resources                                  energy/bandwidth limits, stake yield per TRX
  stake --amount X (--energy | --bandwidth)  stake TRX for a resource (Stake 2.0)
  unstake --amount X (--energy | --bandwidth)  starts the 14-day withdrawal
  withdraw-unfrozen                          claim unstaked TRX past the 14-day wait

Setup
  keygen                                    new key + address (prints the key; store it safely)
  deploy-factory --admin A --guardian G [--fee-token T --fee-recipient R --max-bps 50 --max-cap 1
                 --bps 10 --cap 0.25 --upgrade-delay 3d --pause-duration 7d --fee-limit 2000]
  info                                      factory config, governance state, pending actions

Custodial (DepositForwarder)
  deposit-address --treasury T (--id ID | --salt 0x..) [--sweeper S] [--offline]
  deposit-addresses --treasury T --ids a,b,c | --count N [--prefix user-] [--sweeper S]
  sweep --treasury T (--id ID | --salt 0x..) [--token T | --trx] [--sweeper S]
  sweep-many --file items.json              [{treasury, sweeper?, id? | salt?, token?}, ...]

Non-custodial (PermitAccount)
  account --owner O [--index n] [--token T]  address, deployed, nonce, signer, balances
  transfer --to R --amount X [--token T] [--index n] (--relayer URL [--max-fee X] | --self [--relayer-fee X])
  withdraw --to R --amount X [--token T | --trx] [--index n]       owner exit (never paused)
  set-signer --signer S [--index n]          rotate permit key (zero address = owner key)
  invalidate-nonces --nonce N [--index n]
  fees --amount X [--token T]                protocol fee for an amount
  claim --accounts a,b,... [--token T] [--to R]   claim your accrued fees

Governance (admin / guardian)
  gov status
  gov watch [--interval 60] [--once] [--expect-impl ADDR]... [--webhook URL]...
              alert on queued upgrades/role changes, pauses and fee changes
              (JSON lines on stdout; webhooks signed with TPM_WEBHOOK_SECRET;
               --once exits 3 if an upgrade or role change is queued, for cron/CI)
  gov queue-upgrade --kind account|forwarder --impl ADDR
  gov cancel-upgrade|execute-upgrade --kind account|forwarder
  gov pause | gov unpause
  gov set-fee --bps N --cap X
  gov queue-roles --admin A --guardian G | gov cancel-roles | gov execute-roles

`;

const OPTIONS = {
  network: { type: "string" },
  rpc: { type: "string" },
  factory: { type: "string" },
  json: { type: "boolean" },
  yes: { type: "boolean" },
  help: { type: "boolean", short: "h" },
  version: { type: "boolean", short: "v" },
  offline: { type: "boolean" },
  trx: { type: "boolean" },
  energy: { type: "boolean" },
  bandwidth: { type: "boolean" },
  self: { type: "boolean" },
  treasury: { type: "string" },
  sweeper: { type: "string" },
  salt: { type: "string" },
  id: { type: "string" },
  ids: { type: "string" },
  count: { type: "string" },
  prefix: { type: "string" },
  "start": { type: "string" },
  token: { type: "string", multiple: true },
  owner: { type: "string" },
  index: { type: "string" },
  to: { type: "string" },
  amount: { type: "string" },
  relayer: { type: "string", multiple: true },
  "relayer-fee": { type: "string" },
  "max-fee": { type: "string" },
  signer: { type: "string" },
  nonce: { type: "string" },
  accounts: { type: "string" },
  file: { type: "string" },
  kind: { type: "string" },
  impl: { type: "string" },
  bps: { type: "string" },
  cap: { type: "string" },
  admin: { type: "string" },
  guardian: { type: "string" },
  "fee-token": { type: "string" },
  "fee-recipient": { type: "string" },
  "max-bps": { type: "string" },
  "max-cap": { type: "string" },
  "upgrade-delay": { type: "string" },
  "pause-duration": { type: "string" },
  "fee-limit": { type: "string" },
  interval: { type: "string" },
  once: { type: "boolean" },
  "expect-impl": { type: "string", multiple: true },
} as const;

function duration(s: string): bigint {
  const m = /^(\d+)\s*([smhd]?)$/.exec(s.trim());
  if (!m) throw new UsageError(`invalid duration "${s}" (e.g. 3d, 12h, 3600)`);
  const mult = { "": 1n, s: 1n, m: 60n, h: 3600n, d: 86400n }[m[2] as "" | "s" | "m" | "h" | "d"];
  return BigInt(m[1]) * mult;
}

function kindOf(ctx: Context): Kind {
  const k = ctx.need("kind");
  if (k === "account") return Kind.Account;
  if (k === "forwarder") return Kind.Forwarder;
  throw new UsageError("--kind must be account or forwarder");
}

function firstToken(ctx: Context) {
  const t = ctx.flags.token as unknown as string[] | undefined;
  return t?.[0];
}

async function tokenOrDefault(ctx: Context): Promise<string | undefined> {
  if (ctx.bool("trx")) return undefined;
  const t = firstToken(ctx) ?? ctx.chain.usdt;
  if (!t) throw new UsageError("--token is required on this network");
  return parseTronAddress(t);
}

async function amountFor(ctx: Context, token: string | undefined, flag = "amount") {
  const raw = ctx.need(flag);
  if (!token) return { value: parseUnits(raw, 6), decimals: 6, symbol: "TRX" };
  const info = await getTokenInfo(ctx.rpc, token);
  return { value: parseUnits(raw, info.decimals), ...info };
}

function txOut(ctx: Context, label: string, r: { txid: string; energyUsed?: number }, extra: Record<string, unknown> = {}) {
  ctx.out(`${label}\n  tx: ${explorerTx(ctx.chain, r.txid)}${r.energyUsed ? `\n  energy (simulated): ${r.energyUsed}` : ""}`, {
    txid: r.txid,
    energyUsed: r.energyUsed,
    ...extra,
  });
}

const commands: Record<string, (ctx: Context, args: string[]) => Promise<void>> = {
  async keygen(ctx) {
    const key = generatePrivateKey();
    const address = privateKeyToAccount(key).address;
    ctx.out(`address: ${toBase58(address)}\nprivate key: ${key}\n(store it in a secret manager; export ${ENV.key}=... to use)`, {
      address: toBase58(address),
      hex: address.toLowerCase(),
      privateKey: key,
    });
  },

async resources(ctx) {
    const signer = ctx.signer();
    const [r, trx] = await Promise.all([ctx.rpc.getAccountResources(signer.address), ctx.rpc.getTrxBalance(signer.address)]);
    ctx.out(
      [
        `account    ${toBase58(signer.address)}`,
        `TRX        ${formatUnits(trx, 6)} liquid`,
        `energy     ${r.energyAvailable} available of ${r.energyLimit} /day`,
        `bandwidth  ${r.bandwidthAvailable} available of ${r.netLimit} /day`,
        `yield      1 TRX staked = ${r.energyPerStakedTrx.toFixed(2)} energy/day or ${r.bandwidthPerStakedTrx.toFixed(2)} bandwidth/day`,
      ].join("\n"),
      { ...r, trx: trx.toString() },
    );
  },

  async stake(ctx) {
    const { signer, amount, resource } = stakeArgs(ctx, "stake");
    const txid = await freezeBalance(ctx.rpc, signer, amount, resource);
    txOut(ctx, `staked ${formatUnits(amount, 6)} TRX for ${resource.toLowerCase()}`, { txid });
  },

  async unstake(ctx) {
    const { signer, amount, resource } = stakeArgs(ctx, "unstake");
    const txid = await unfreezeBalance(ctx.rpc, signer, amount, resource);
    txOut(ctx, `unstaking ${formatUnits(amount, 6)} TRX from ${resource.toLowerCase()}; withdraw with 'withdraw-unfrozen' after 14 days`, { txid });
  },

  async "withdraw-unfrozen"(ctx) {
    ctx.confirmWrite("withdraw unfrozen TRX");
    const txid = await withdrawExpireUnfreeze(ctx.rpc, ctx.signer());
    txOut(ctx, "withdrew expired unfreezes", { txid });
  },

  async "deploy-factory"(ctx) {
    ctx.confirmWrite("deploy a factory");
    const signer = ctx.signer();
    const feeToken = ctx.str("fee-token") ?? ctx.chain.usdt ?? "0x0000000000000000000000000000000000000000";
    const feesOn = Number(ctx.str("max-bps") ?? 50) !== 0;
    const dec = feesOn && !/^0x0{40}$/i.test(parseTronAddress(feeToken)) ? (await getTokenInfo(ctx.rpc, feeToken)).decimals : 6;
    const maxCap = ctx.str("max-cap") ? parseUnits(ctx.str("max-cap")!, dec) : parseUnits("1", dec);
    const cap = ctx.str("cap") ? parseUnits(ctx.str("cap")!, dec) : parseUnits("0.25", dec);
    const cfg = {
      feeToken,
      feeRecipient: ctx.str("fee-recipient") ?? signer.address,
      maxBps: Number(ctx.str("max-bps") ?? 50),
      maxCap,
      bps: Number(ctx.str("bps") ?? 10),
      cap,
      admin: ctx.need("admin"),
      guardian: ctx.need("guardian"),
      upgradeDelay: duration(ctx.str("upgrade-delay") ?? "3d"),
      pauseDuration: duration(ctx.str("pause-duration") ?? "7d"),
    };
    const feeLimit = parseUnits(ctx.str("fee-limit") ?? "2000", 6);
    const r = await deployFactory(ctx.rpc, signer, cfg, feeLimit);
    ctx.out(`PaymasterFactory deployed\n  address: ${toBase58(r.address)}\n  tx: ${explorerTx(ctx.chain, r.txid)}\n  export ${ENV.factory}=${toBase58(r.address)}`, {
      factory: toBase58(r.address),
      factoryHex: r.address,
      txid: r.txid,
      energy: r.info.receipt?.energy_usage_total,
    });
  },

  async info(ctx) {
    const c = ctx.client();
    const i = await c.getFactoryInfo();
    const [uf, ua, roles] = await Promise.all([c.getPendingUpgrade(Kind.Forwarder), c.getPendingUpgrade(Kind.Account), c.getPendingRoles()]);
    const tok = i.feeToken !== ZERO_ADDRESS ? await c.tokenInfo(i.feeToken).catch(() => ({ decimals: 6, symbol: "?" })) : { decimals: 6, symbol: "-" };
    const pend = (p: { implementation: string; eta: bigint }) => (p.eta === 0n ? "none" : `${toBase58(p.implementation)} at ${new Date(Number(p.eta) * 1000).toISOString()}`);
    ctx.out(
      [
        `factory           ${toBase58(i.factory)} (${ctx.chain.name})`,
        `forwarder router  ${toBase58(i.forwarderRouter)}  impl ${toBase58(i.forwarderImplementation)}`,
        `account router    ${toBase58(i.accountRouter)}  impl ${toBase58(i.accountImplementation)}`,
        `admin             ${toBase58(i.admin)}`,
        `guardian          ${toBase58(i.guardian)}`,
        `upgrade delay     ${Number(i.upgradeDelay) / 3600}h   pause duration ${Number(i.pauseDuration) / 3600}h`,
        `paused            ${i.paused ? `YES until ${new Date(Number(i.pausedUntil) * 1000).toISOString()}` : "no"}`,
        `protocol fee      ${i.bps} bps, cap ${fmtAmount(i.cap, tok.decimals, tok.symbol)} (max ${i.maxBps} bps / ${fmtAmount(i.maxCap, tok.decimals, tok.symbol)})`,
        `fee token         ${i.feeToken === ZERO_ADDRESS ? "none" : toBase58(i.feeToken)}  recipient ${toBase58(i.feeRecipient)}`,
        `pending upgrade   forwarder: ${pend(uf)}; account: ${pend(ua)}`,
        `pending roles     ${roles.eta === 0n ? "none" : `admin ${toBase58(roles.admin)}, guardian ${toBase58(roles.guardian)} at ${new Date(Number(roles.eta) * 1000).toISOString()}`}`,
      ].join("\n"),
      { ...i, pendingUpgrades: { forwarder: uf, account: ua }, pendingRoles: roles },
    );
  },

  async "deposit-address"(ctx) {
    const treasury = ctx.need("treasury");
    const sweeper = ctx.str("sweeper");
    const salt = await ctx.salt();
    let address: string;
    if (ctx.bool("offline")) {
      const factory = ctx.str("factory") ?? process.env[ENV.factory];
      const router = process.env.TPM_FORWARDER_ROUTER;
      if (!factory || !router) throw new UsageError(`--offline needs --factory and TPM_FORWARDER_ROUTER`);
      address = getForwarderAddress({ factory, forwarderRouter: router, treasury, sweeper, salt });
    } else {
      address = await ctx.client().predictForwarder(treasury, salt, sweeper);
    }
    ctx.out(toBase58(address), { address: toBase58(address), hex: parseTronAddress(address), salt, treasury: toBase58(treasury), sweeper: sweeper ? toBase58(sweeper) : null });
  },

  async "deposit-addresses"(ctx) {
    const c = ctx.client();
    const { forwarderRouter } = await c.getDeployment();
    const treasury = ctx.need("treasury");
    const sweeper = ctx.str("sweeper");
    const secret = depositSecret();
    let ids: string[];
    if (ctx.str("ids")) ids = ctx.need("ids").split(",").map((s) => s.trim()).filter(Boolean);
    else {
      const n = Number(ctx.need("count"));
      const start = Number(ctx.str("start") ?? 0);
      ids = Array.from({ length: n }, (_, i) => `${ctx.str("prefix") ?? ""}${start + i}`);
    }
    // Cross-check the off-chain derivation once against the factory.
    const firstSalt = await deriveDepositSalt(secret, ids[0]!);
    await c.predictForwarder(treasury, firstSalt, sweeper);
    const rows = [];
    for (const id of ids) {
      const salt = await deriveDepositSalt(secret, id);
      const address = getForwarderAddress({ factory: c.factory, forwarderRouter, treasury, sweeper, salt });
      rows.push({ id, address: toBase58(address), salt });
    }
    ctx.out(rows.map((r) => `${r.id}\t${r.address}`).join("\n"), rows);
  },

  async sweep(ctx) {
    ctx.confirmWrite("sweep");
    const c = ctx.client({ signer: true });
    const token = await tokenOrDefault(ctx);
    const item: SweepItem = { treasury: ctx.need("treasury"), sweeper: ctx.str("sweeper"), salt: await ctx.salt(), token };
    const forwarder = await c.predictForwarder(item.treasury, item.salt, item.sweeper);
    const bal = token ? await c.balanceOf(token, forwarder) : await ctx.rpc.getTrxBalance(forwarder);
    if (bal === 0n) {
      ctx.out(`nothing to sweep at ${toBase58(forwarder)}`, { forwarder: toBase58(forwarder), amount: "0" });
      return;
    }
    const r = await c.sweep(item);
    txOut(ctx, `swept ${bal} base units from ${toBase58(forwarder)} to ${toBase58(item.treasury)}`, r, { forwarder: toBase58(forwarder), amount: bal });
  },

  async "sweep-many"(ctx) {
    ctx.confirmWrite("sweep");
    const c = ctx.client({ signer: true });
    const raw = JSON.parse(readFileSync(ctx.need("file"), "utf8")) as Array<{ treasury: string; sweeper?: string; id?: string; salt?: Hex; token?: string }>;
    const items: SweepItem[] = [];
    for (const r of raw) {
      const salt = r.salt ?? (r.id ? await deriveDepositSalt(depositSecret(), r.id) : undefined);
      if (!salt) throw new UsageError("each item needs salt or id");
      items.push({ treasury: r.treasury, sweeper: r.sweeper, salt, token: r.token });
    }
    const res = await c.sweepMany(items);
    txOut(ctx, `swept ${items.length} forwarders`, res, { count: items.length });
  },

  async account(ctx) {
    const c = ctx.client();
    const owner = ctx.str("owner") ?? ctx.signer().address;
    const index = BigInt(ctx.str("index") ?? 0);
    const s = await c.getAccountState(owner, index);
    const token = await tokenOrDefault(ctx);
    let bal = "";
    let balances: Record<string, unknown> = {};
    if (token) {
      const t = await c.tokenInfo(token);
      const b = await c.getAccountBalances(s.address, token);
      balances = b;
      bal = `\nbalance   ${fmtAmount(b.balance, t.decimals, t.symbol)}  (available ${fmtAmount(b.available, t.decimals, t.symbol)}, fees owed ${fmtAmount(b.totalOwed, t.decimals, t.symbol)})`;
    }
    ctx.out(
      `account   ${toBase58(s.address)}\nowner     ${toBase58(s.owner)} (index ${s.index})\ndeployed  ${s.deployed}\nnonce     ${s.nonce}\nsigner    ${toBase58(s.signer)}${bal}`,
      { ...s, address: toBase58(s.address), owner: toBase58(s.owner), signer: toBase58(s.signer), ...balances },
    );
  },

  async transfer(ctx) {
    const token = (await tokenOrDefault(ctx))!;
    if (!token) throw new UsageError("transfer moves TRC-20 tokens; use withdraw for TRX");
    const to = ctx.need("to");
    const index = BigInt(ctx.str("index") ?? 0);
    const { value, decimals, symbol } = await amountFor(ctx, token);
    const key = process.env[ENV.key];
    if (!key) throw new UsageError(`set ${ENV.key} to the account owner's key`);
    const owner = fromPrivateKey((key.startsWith("0x") ? key : `0x${key}`) as Hex);
    const relayers = ctx.flags.relayer as unknown as string[] | undefined;

    if (relayers?.length) {
      const rc = createRelayerClient({ url: relayers });
      const maxFee = ctx.str("max-fee") ? parseUnits(ctx.need("max-fee"), decimals) : undefined;
      const q = await rc.quote({ owner: owner.address, index, token, to, value, maxFee });
      const c = ctx.client();
      const state = await c.getAccountState(owner.address, index);
      if (q.account !== state.address) throw new Error("relayer quoted a different account address");
      if (BigInt(q.nonce) !== state.nonce) throw new Error("relayer quoted a stale nonce");
      const fee = BigInt(q.relayerFee) + BigInt(q.protocolFee);
      if (!ctx.json) process.stderr.write(`fee: ${fmtAmount(fee, decimals, symbol)} (relayer ${fmtAmount(BigInt(q.relayerFee), decimals, symbol)})\n`);
      const permit = q.unsignedPermit;
      if (permit.value !== value || parseTronAddress(permit.to) !== parseTronAddress(to) || parseTronAddress(permit.token) !== token) {
        throw new Error("relayer returned a permit that does not match the request");
      }
      const sig = await c.signPermit(owner, permit, state.address, state.signer);
      // Stable per permit, so a retried command never pays twice.
      const sub = await rc.submit({ permit, signature: sig, index, quoteId: q.quoteId, idempotencyKey: `cli:${state.address}:${permit.nonce}` });
      const st = await rc.waitForPermit(sub.id);
      if (st.status !== "INCLUDED") throw new Error(`relayed transfer ${st.status}: ${st.error ?? ""}`);
      txOut(ctx, `sent ${fmtAmount(value, decimals, symbol)} to ${toBase58(to)} via ${sub.relayer}`, { txid: st.txid ?? sub.txid ?? "" }, { fee: fee.toString() });
      return;
    }
    if (!ctx.bool("self")) throw new UsageError("pass --relayer <url> or --self");
    ctx.confirmWrite("transfer");
    // Self-relay: the same key pays energy and signs the permit.
    const c = ctx.client({ signer: true });
    const relayerFee = ctx.str("relayer-fee") ? parseUnits(ctx.need("relayer-fee"), decimals) : 0n;
    const prep = await c.preparePermit({ owner: owner.address, index, token, to, value, relayerFee, relayer: c.signer!.address, ttlSeconds: Number(ctx.str("ttl") ?? 180) });
    const sig = await c.signPermit(owner, prep.permit, prep.account, prep.signer);
    const r = await c.submitPermit({ permit: prep.permit, signature: sig, index, relayerFee });
    txOut(ctx, `sent ${fmtAmount(value, decimals, symbol)} to ${toBase58(to)} from ${toBase58(r.account)}`, r, { account: toBase58(r.account) });
  },

  async withdraw(ctx) {
    ctx.confirmWrite("withdraw");
    const c = ctx.client({ signer: true });
    const token = await tokenOrDefault(ctx);
    const { value, decimals, symbol } = await amountFor(ctx, token);
    const r = await c.withdraw({ index: BigInt(ctx.str("index") ?? 0), token, to: ctx.need("to"), amount: value });
    txOut(ctx, `withdrew ${fmtAmount(value, decimals, symbol)}`, r);
  },

  async "set-signer"(ctx) {
    ctx.confirmWrite("rotate the signer");
    const r = await ctx.client({ signer: true }).setSigner({ index: BigInt(ctx.str("index") ?? 0), signer: ctx.need("signer") });
    txOut(ctx, "signer updated", r);
  },

  async "invalidate-nonces"(ctx) {
    ctx.confirmWrite("invalidate nonces");
    const r = await ctx.client({ signer: true }).invalidateNonces({ index: BigInt(ctx.str("index") ?? 0), newNonce: BigInt(ctx.need("nonce")) });
    txOut(ctx, "nonces invalidated", r);
  },

  async fees(ctx) {
    const c = ctx.client();
    const token = (await tokenOrDefault(ctx))!;
    const { value, decimals, symbol } = await amountFor(ctx, token);
    const fee = await c.protocolFee(token, value);
    ctx.out(`protocol fee: ${fmtAmount(fee, decimals, symbol)}`, { protocolFee: fee.toString() });
  },

  async claim(ctx) {
    ctx.confirmWrite("claim fees");
    const c = ctx.client({ signer: true });
    const token = (await tokenOrDefault(ctx))!;
    const accounts = ctx.need("accounts").split(",").map((a) => parseTronAddress(a.trim()));
    const r = await c.claimMany({ accounts, token, to: ctx.str("to") });
    txOut(ctx, `claimed from ${accounts.length} accounts`, r);
  },

  async gov(ctx, args) {
    const sub = args[0];
    if (!sub || sub === "status") return commands.info!(ctx, []);
    if (sub === "watch") return govWatch(ctx);
    ctx.confirmWrite(`run gov ${sub}`);
    const c = ctx.client({ signer: true });
    let r;
    switch (sub) {
      case "queue-upgrade":
        r = await c.gov.queueUpgrade(kindOf(ctx), ctx.need("impl"));
        break;
      case "cancel-upgrade":
        r = await c.gov.cancelUpgrade(kindOf(ctx));
        break;
      case "execute-upgrade":
        r = await c.gov.executeUpgrade(kindOf(ctx));
        break;
      case "pause":
        r = await c.gov.pause();
        break;
      case "unpause":
        r = await c.gov.unpause();
        break;
      case "set-fee": {
        const info = await c.getFactoryInfo();
        const dec = (await c.tokenInfo(info.feeToken).catch(() => ({ decimals: 6 }))).decimals;
        r = await c.gov.setProtocolFee(Number(ctx.need("bps")), parseUnits(ctx.need("cap"), dec));
        break;
      }
      case "queue-roles":
        r = await c.gov.queueRoles(ctx.need("admin"), ctx.need("guardian"));
        break;
      case "cancel-roles":
        r = await c.gov.cancelRoles();
        break;
      case "execute-roles":
        r = await c.gov.executeRoles();
        break;
      default:
        throw new UsageError(`unknown gov command "${sub}"`);
    }
    txOut(ctx, `gov ${sub} done`, r);
  },

};

const trxToSun = (v: string | undefined) => {
  if (v === undefined) return undefined;
  if (!/^\d+(\.\d{1,6})?$/.test(v)) throw new UsageError(`bad TRX amount ${v}`);
  return parseUnits(v, 6);
};

function webhookEndpoints(ctx: Context) {
  const urls = (ctx.flags.webhook as unknown as string[] | undefined) ?? [];
  const secret = process.env.TPM_WEBHOOK_SECRET;
  if (urls.length && (!secret || secret.length < 32)) throw new UsageError("set TPM_WEBHOOK_SECRET (>= 32 chars) to use --webhook");
  return urls.map((url) => ({ url, secret: secret! }));
}

async function govWatch(ctx: Context) {
  const client = ctx.client();
  const webhooks = createWebhookDispatcher({ endpoints: webhookEndpoints(ctx) });
  const emit = (a: GovernanceAlert) =>
    process.stdout.write(`${JSON.stringify({ t: new Date().toISOString(), ...a }, (_k, v) => (typeof v === "bigint" ? v.toString() : v))}\n`);
  const watcher = createGovernanceWatcher({
    client,
    intervalMs: Number(ctx.str("interval") ?? 60) * 1000,
    expectedImplementations: ((ctx.flags["expect-impl"] as unknown as string[] | undefined) ?? []).map((a) => parseTronAddress(a)),
    onAlert: emit,
    webhooks,
    onError: (e) => process.stderr.write(`${JSON.stringify({ t: new Date().toISOString(), error: e.message })}\n`),
  });
  if (ctx.bool("once")) {
    const alerts = await watcher.poll();
    await watcher.stop();
    if (!alerts.length) process.stderr.write("no pending governance actions\n");
    process.exitCode = alerts.some((a) => a.severity === "critical") ? 3 : 0;
    return;
  }
  process.stderr.write(`watching ${client.factory} on ${ctx.chain.name}\n`);
  watcher.start();
  for (const sig of ["SIGINT", "SIGTERM"] as const) process.once(sig, () => void watcher.stop().then(() => process.exit(0)));
  await new Promise(() => {});
}

function stakeArgs(ctx: Context, what: string) {
  ctx.confirmWrite(what);
  const energy = ctx.bool("energy");
  const bandwidth = ctx.bool("bandwidth");
  if (energy === bandwidth) throw new UsageError(`pass exactly one of --energy or --bandwidth`);
  const amount = parseUnits(ctx.need("amount"), 6);
  if (amount <= 0n) throw new UsageError("--amount must be positive TRX");
  return { signer: ctx.signer(), amount, resource: (energy ? "ENERGY" : "BANDWIDTH") as StakeResource };
}


export async function main(argv = process.argv.slice(2)): Promise<number> {
  let parsed;
  try {
    parsed = parseArgs({ args: argv, options: OPTIONS, allowPositionals: true, strict: true });
  } catch (e) {
    process.stderr.write(`${(e as Error).message}\n\n${HELP}`);
    return 2;
  }
  const flags = parsed.values as unknown as Flags;
  const [cmd, ...rest] = parsed.positionals;
  if (flags.version) {
    process.stdout.write(`${VERSION}\n`);
    return 0;
  }
  if (!cmd || flags.help || cmd === "help") {
    process.stdout.write(HELP);
    return cmd || flags.help ? 0 : 2;
  }
  const fn = commands[cmd];
  if (!fn) {
    process.stderr.write(`unknown command "${cmd}"\n\n${HELP}`);
    return 2;
  }
  try {
    await fn(makeContext(flags), rest);
    return 0;
  } catch (e) {
    const err = e as Error;
    if (flags.json) process.stderr.write(`${JSON.stringify({ error: err.message })}\n`);
    else process.stderr.write(`error: ${err.message}\n`);
    return e instanceof UsageError ? 2 : 1;
  }
}

export { formatUnits };
