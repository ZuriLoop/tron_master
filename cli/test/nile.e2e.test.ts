/**
 * End-to-end on the Nile testnet with the real TetherToken (USDT) contract.
 *
 *   NILE_PRIVATE_KEY=0x… pnpm --filter @tron-paymaster/cli test:nile
 *
 * The funded key is admin, relayer, fee recipient and treasury, so swept and
 * withdrawn USDT flows back to it. The guardian key is derived from it. The
 * factory is deployed once and reused via test/nile-deployment.json (delete
 * the file, or set NILE_REDEPLOY=1, to deploy a new one).
 *
 * Writes measured energy/bandwidth/fees per operation to test/results/.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import type { AddressInfo } from "node:net";
import {
  type Hex,
  type PaymasterClient,
  type TransactionInfo,
  TronRpc,
  ZERO_ADDRESS,
  createPaymasterClient,
  createRelayerClient,
  deriveDepositSalt,
  fromPrivateKey,
  getForwarderAddress,
  getPermitAccountAddress,
  parseTronAddress,
  toBase58,
  transferTrx,
  tronNile,
  tronSignerFromPrivateKey,
} from "@tron-paymaster/sdk";
import { concat, keccak256, toHex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deployFactory } from "../src/deploy.js";

const KEY = process.env.NILE_PRIVATE_KEY as Hex | undefined;
const run = KEY ? describe : describe.skip;
const DEPLOYMENT_FILE = new URL("./nile-deployment.json", import.meta.url);
const RESULTS_DIR = new URL("./results/", import.meta.url);
const USDT = tronNile.usdt!;
const TRX = 1_000_000n;
const U = 1_000_000n; // 1 USDT (6 dp)

interface Measurement {
  op: string;
  txid: string;
  energy?: number;
  energyFee?: number;
  netUsage?: number;
  netFee?: number;
  originEnergy?: number;
  feeSun?: number;
}

run("Nile end-to-end (real USDT)", () => {
  const rpc = new TronRpc({ url: tronNile.rpcUrl, apiKey: process.env.TRON_API_KEY });
  const chain = { ...tronNile };
  const funder = tronSignerFromPrivateKey(KEY!);
  const guardianKey = keccak256(concat([KEY!, toHex("tron-paymaster/nile/guardian")]));
  const guardian = tronSignerFromPrivateKey(guardianKey);
  const runId = `${Date.now()}`;
  const measurements: Measurement[] = [];
  let factory: string;
  let client: PaymasterClient;

  const ownerKey = generatePrivateKey();
  const owner = privateKeyToAccount(ownerKey).address;
  const recipient = privateKeyToAccount(generatePrivateKey()).address; // fresh: zero USDT

  const record = (op: string, txid: string, info?: TransactionInfo) => {
    measurements.push({
      op,
      txid,
      energy: info?.receipt?.energy_usage_total,
      energyFee: info?.receipt?.energy_fee,
      netUsage: info?.receipt?.net_usage,
      netFee: info?.receipt?.net_fee,
      originEnergy: info?.receipt?.origin_energy_usage,
      feeSun: info?.fee,
    });
  };

  beforeAll(async () => {
    const trx = await rpc.getTrxBalance(funder.address);
    const probe = createPaymasterClient({ chain, rpc, factory: USDT });
    const usdt = await probe.balanceOf(USDT, funder.address);
    console.log(`funder ${toBase58(funder.address)}: ${Number(trx) / 1e6} TRX, ${Number(usdt) / 1e6} USDT`);

    let saved: { factory?: string } = {};
    if (existsSync(DEPLOYMENT_FILE) && !process.env.NILE_REDEPLOY) saved = JSON.parse(readFileSync(DEPLOYMENT_FILE, "utf8"));
    /**
     * A saved factory is only reusable if its bytecode matches this branch.
     * The energy diet changed the ABI (packed entrypoint, FEE_TOKEN immutable,
     * deployAndPermit arity), so an older factory would fail with confusing
     * reverts. PermitAccount.FEE_TOKEN() exists only post-diet: probe it and
     * redeploy when it is missing.
     */
    const abiMatches = async (addr: string) => {
      try {
        const c = createPaymasterClient({ chain, rpc, factory: addr });
        const impl = (await c.getFactoryInfo()).accountImplementation;
        await c.read(impl, [{ type: "function", name: "FEE_TOKEN", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" }], "FEE_TOKEN");
        return true;
      } catch {
        return false;
      }
    };
    let reuse = Boolean(saved.factory) && (await rpc.hasCode(saved.factory!));
    if (reuse && !(await abiMatches(saved.factory!))) {
      console.log(`saved factory ${saved.factory} predates the current contracts; deploying a fresh one`);
      reuse = false;
    }
    const needTrx = reuse ? 150n * TRX : 750n * TRX;
    if (trx < needTrx) throw new Error(`fund ${toBase58(funder.address)} with >= ${needTrx / TRX} TRX on Nile (has ${trx / TRX})`);
    if (usdt < 8n * U) throw new Error(`fund ${toBase58(funder.address)} with >= 8 Nile USDT (has ${Number(usdt) / 1e6})`);

    if (reuse) {
      factory = saved.factory!;
      // A reused factory was not necessarily deployed by this suite — the
      // mainnet rehearsal is deployed by hand, with different roles — so the
      // config assertions below check it against what it actually is.
      console.log(`reusing factory ${toBase58(factory)}`);
    } else {
      // Guardian needs TRX for pause/veto transactions.
      if ((await rpc.getTrxBalance(guardian.address)) < 20n * TRX) await transferTrx(rpc, funder, guardian.address, 30n * TRX);
      const r = await deployFactory(
        rpc,
        funder,
        {
          feeToken: USDT,
          feeRecipient: funder.address,
          maxBps: 50,
          maxCap: 1n * U,
          bps: 10,
          cap: 250_000n,
          admin: funder.address,
          guardian: guardian.address,
          upgradeDelay: 2n * 86400n,
          pauseDuration: 3600n,
        },
        2_000n * TRX,
      );
      factory = r.address;
      record("deployFactory", r.txid, r.info);
      const c = createPaymasterClient({ chain, rpc, factory });
      const d = await c.getDeployment();
      writeFileSync(
        DEPLOYMENT_FILE,
        `${JSON.stringify(
          {
            network: "nile",
            factory: toBase58(factory),
            forwarderRouter: toBase58(d.forwarderRouter),
            accountRouter: toBase58(d.accountRouter),
            admin: toBase58(funder.address),
            guardian: toBase58(guardian.address),
            feeToken: toBase58(USDT),
            deployTx: r.txid,
            deployedAt: new Date().toISOString(),
          },
          null,
          2,
        )}\n`,
      );
      console.log(`deployed factory ${toBase58(factory)} in ${r.txid}`);
    }
    client = createPaymasterClient({ chain, rpc, factory, signer: funder });
  }, 600_000);

  it("factory config is as deployed", async () => {
    const i = await client.getFactoryInfo();
    // The suite signs as the admin, so that one has to be the funder.
    expect(i.admin).toBe(funder.address);
    // The guardian only has to be a second party: it signs nothing here (pause
    // and unpause both go through the admin), and a hand-deployed factory uses
    // a different key than the one this suite derives.
    expect(i.guardian).not.toBe(ZERO_ADDRESS);
    expect(i.guardian).not.toBe(i.admin);
    expect(i.feeToken).toBe(USDT);
    expect(i.paused).toBe(false);
  });

  it("SDK predictions match the factory (0x41 CREATE2 on Nile)", async () => {
    const { forwarderRouter, accountRouter } = await client.getDeployment();
    const salt = await deriveDepositSalt(`nile-e2e-${runId}-secret-0123456789`, "parity");
    expect(await client.predictForwarder(funder.address, salt)).toBe(
      getForwarderAddress({ factory, forwarderRouter, treasury: funder.address, salt }),
    );
    expect(await client.predictAccount(owner)).toBe(getPermitAccountAddress({ factory, accountRouter, owner }));
  });

  it("custodial: USDT to an undeployed forwarder, then deploy+sweep; then a plain sweep", async () => {
    const salt = await deriveDepositSalt(`nile-e2e-${runId}-secret-0123456789`, "usdt");
    const fwd = await client.predictForwarder(funder.address, salt);
    expect(await rpc.hasCode(fwd)).toBe(false);
    const dep = await client.transferToken(USDT, fwd, 1n * U);
    record("usdtTransfer(newHolder)", dep.txid, dep.info);
    expect(await client.balanceOf(USDT, fwd)).toBe(1n * U);

    const before = await client.balanceOf(USDT, funder.address);
    const s1 = await client.sweep({ treasury: funder.address, salt, token: USDT });
    record("forwarder.deployAndSweep", s1.txid, s1.info);
    expect(s1.info.receipt?.origin_energy_usage ?? 0).toBe(0);
    expect(await rpc.hasCode(fwd)).toBe(true);
    expect((await client.balanceOf(USDT, funder.address)) - before).toBe(1n * U);

    await client.transferToken(USDT, fwd, U / 2n);
    const s2 = await client.sweep({ treasury: funder.address, salt, token: USDT });
    record("forwarder.sweep(deployed)", s2.txid, s2.info);
    expect(await client.balanceOf(USDT, fwd)).toBe(0n);
  }, 300_000);

  it("custodial: TRX to a forwarder is swept to the treasury", async () => {
    const salt = await deriveDepositSalt(`nile-e2e-${runId}-secret-0123456789`, "trx");
    const fwd = await client.predictForwarder(funder.address, salt);
    await transferTrx(rpc, funder, fwd, 2n * TRX);
    const s = await client.sweep({ treasury: funder.address, salt });
    record("forwarder.deployAndSweepTRX", s.txid, s.info);
    expect(await rpc.getTrxBalance(fwd)).toBe(0n);
  }, 300_000);

afterAll(() => {
    if (!measurements.length) return;
    mkdirSync(RESULTS_DIR, { recursive: true });
    const out = { network: "nile", factory: factory && toBase58(factory), at: new Date().toISOString(), usdt: toBase58(USDT), measurements };
    writeFileSync(new URL(`nile-${runId}.json`, RESULTS_DIR), `${JSON.stringify(out, null, 2)}\n`);
    console.log("\nNile measurements (energy / bandwidth / burned TRX):");
    for (const m of measurements) {
      console.log(`  ${m.op.padEnd(38)} ${String(m.energy ?? "?").padStart(9)}  ${String(m.netUsage ?? 0).padStart(4)}B  ${((m.feeSun ?? 0) / 1e6).toFixed(2)} TRX  ${m.txid}`);
    }
  });
});
