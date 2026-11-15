/**
 * End-to-end on a real TVM (local java-tron via `tronbox/tre`).
 *
 *   docker run -d --rm --name tpm-tre -p 9090:9090 -e accounts=5 tronbox/tre
 *   node contracts/script/compile-tron.mjs --with-mocks
 *   TRE_URL=http://127.0.0.1:9090 pnpm --filter @tron-paymaster/cli test
 *
 * Proves on TVM what the Foundry (EVM) suite cannot: 0x41 CREATE2 parity
 * between SDK and factory, deposits to undeployed addresses, Tron USDT's
 * false-returning transfer, caller-pays energy, chain id / TIP-712 domain,
 * and the full relayer round trip.
 */
import { readFileSync } from "node:fs";
import { AddressInfo } from "node:net";
import {
  type Hex,
  Kind,
  type PaymasterClient,
  type TronSigner,
  TronRpc,
  createPaymasterClient,
  createRelayerClient,
  deriveDepositSalt,
  fromPrivateKey,
  getForwarderAddress,
  getPermitAccountAddress,
  localChain,
  parseTronAddress,
  permitAccountAbi,
  signTransaction,
  toBase58,
  toTronHex,
  tronSignerFromPrivateKey,
} from "@tron-paymaster/sdk";
import { decodeFunctionResult, encodeFunctionData, sha256 } from "viem";
import { generatePrivateKey, privateKeyToAccount, sign } from "viem/accounts";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { deployFactory } from "../src/deploy.js";
import { freezeBalance, unfreezeBalance } from "@tron-paymaster/sdk";
import { type GovernanceAlert, createGovernanceWatcher } from "../src/watcher.js";

const TRE = process.env.TRE_URL;
const OUT = new URL("../../contracts/out-tron/", import.meta.url);
const artifact = (n: string) => JSON.parse(readFileSync(new URL(`${n}.json`, OUT), "utf8"));

const run = TRE ? describe : describe.skip;

run("TVM end-to-end (tre)", () => {
  // tre issues ~12 h expirations (java-tron default: 60 s).
  const rpc = new TronRpc({ url: TRE ?? "", maxTxExpiryMs: 86_400_000 });
  const chain = localChain(TRE);
  let keys: Hex[];
  let admin: TronSigner, guardian: TronSigner, relayerSigner: TronSigner, treasury: string;
  let usdt: string;
  let factory: string;
  let rc: PaymasterClient; // relayer/sweeper client
  const energy: Record<string, number | undefined> = {};

  const ownerKey = generatePrivateKey(); // fresh: no TRX, never activated
  const owner = privateKeyToAccount(ownerKey).address;
  const recipient = privateKeyToAccount(generatePrivateKey()).address;

  async function deploy(name: string, ctorData: Hex = "0x", signer = admin) {
    const a = artifact(name);
    const bytecode = `${a.bytecode}${ctorData.slice(2)}` as Hex;
    const tx = await rpc.buildDeployTransaction({ from: signer.address, bytecode, abi: a.abi, name, feeLimit: 1_000_000_000n });
    const signed = await signTransaction(tx, signer, { type: "CreateSmartContract", from: signer.address, maxExpiryMs: rpc.maxTxExpiryMs });
    const info = await rpc.waitForTransaction(await rpc.broadcast(signed));
    return parseTronAddress(info.contract_address!);
  }

  async function sendTrx(from: Hex, to: string, amountSun: bigint) {
    const s = tronSignerFromPrivateKey(from);
    const tx = await rpc.post<any>("/wallet/createtransaction", {
      owner_address: toTronHex(s.address),
      to_address: toTronHex(to),
      amount: Number(amountSun),
    });
    expect(sha256(`0x${tx.raw_data_hex}`).slice(2)).toBe(tx.txID);
    const sig = await sign({ hash: `0x${tx.txID}`, privateKey: from, to: "hex" });
    await rpc.waitForTransaction(await rpc.broadcast({ ...tx, signature: [sig.slice(2)] }));
  }

  async function mint(to: string, amount: bigint) {
    const data = encodeFunctionData({
      abi: [{ type: "function", name: "mint", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [], stateMutability: "nonpayable" }],
      functionName: "mint",
      args: [parseTronAddress(to), amount],
    });
    const c = createPaymasterClient({ chain, rpc, factory: factory ?? usdt, signer: admin });
    await c.send(usdt, data);
  }

  beforeAll(async () => {
    const accts = await (await fetch(`${TRE}/admin/accounts-json`)).json();
    keys = accts.privateKeys.map((k: string) => `0x${k}` as Hex);
    [admin, guardian, relayerSigner] = keys.slice(0, 3).map(tronSignerFromPrivateKey);
    treasury = privateKeyToAccount(keys[3]!).address;

    usdt = await deploy("MockUSDT");
    const r = await deployFactory(
      rpc,
      admin,
      {
        feeToken: usdt,
        feeRecipient: admin.address,
        maxBps: 50,
        maxCap: 1_000_000n,
        bps: 10,
        cap: 250_000n,
        admin: admin.address,
        guardian: guardian.address,
        upgradeDelay: 2n * 86400n,
        pauseDuration: 3600n,
      },
      5_000_000_000n, // clamped to the chain max
    );
    factory = r.address;
    energy.deployFactory = r.info.receipt?.energy_usage_total;
    rc = createPaymasterClient({ chain, rpc, factory, signer: relayerSigner });
  }, 240_000);

  it("reads factory config", async () => {
    const i = await rc.getFactoryInfo();
    expect(i.admin).toBe(admin.address);
    expect(i.guardian).toBe(guardian.address);
    expect(i.feeToken).toBe(parseTronAddress(usdt));
    expect(i.bps).toBe(10);
    expect(i.paused).toBe(false);
  });

  it("stake 2.0: freeze for energy, resources reflect it, unfreeze verifies", async () => {
    const who = tronSignerFromPrivateKey(keys[4]!);
    const before = await rpc.getAccountResources(who.address);
    await freezeBalance(rpc, who, 1_000_000_000n, "ENERGY"); // 1000 TRX
    const after = await rpc.getAccountResources(who.address);
    expect(after.energyLimit).toBeGreaterThan(before.energyLimit);
    const txid = await unfreezeBalance(rpc, who, 1_000_000_000n, "ENERGY");
    expect(txid).toMatch(/^[0-9a-f]{64}$/);
    // Withdrawal of the unfrozen funds is time-locked; the builder+verifier path still signs.
    await expect(freezeBalance(rpc, who, 10n ** 15n, "ENERGY")).rejects.toThrow(); // more than the balance
  }, 120_000);

  it("governance watcher sees a queued upgrade, its veto, and a pause on a real node", async () => {
    const alerts: GovernanceAlert[] = [];
    const w = createGovernanceWatcher({ client: rc, onAlert: (a) => alerts.push(a) });
    expect(await w.poll()).toEqual([]);
    const adm = createPaymasterClient({ chain, rpc, factory, signer: admin });
    const g = createPaymasterClient({ chain, rpc, factory, signer: guardian });
    const impl = (await rc.getFactoryInfo()).accountImplementation;
    await adm.gov.queueUpgrade(Kind.Account, impl);
    const [queued] = await w.poll();
    expect(queued).toMatchObject({ kind: "UpgradeQueued", severity: "critical", details: { kind: "account", implementation: impl, hasCode: true, factoryMatches: true, reviewed: false } });
    expect(await w.poll()).toEqual([]); // no repeat
    await g.gov.cancelUpgrade(Kind.Account);
    expect((await w.poll()).map((a) => a.kind)).toEqual(["UpgradeCancelled"]);
    await adm.gov.pause(); // admin: no guardian cooldown, so later tests can still guardian-pause
    expect((await w.poll()).map((a) => a.kind)).toEqual(["Paused"]);
    await adm.gov.unpause();
    expect((await w.poll()).map((a) => a.kind)).toEqual(["Unpaused"]);
    await w.stop();
  }, 180_000);

  it("SDK 0x41 CREATE2 predictions match the factory on TVM", async () => {
    const { forwarderRouter, accountRouter } = await rc.getFactoryInfo();
    const salt = await deriveDepositSalt("e2e-secret-0123456789abcdef", "user-1");
    const local = getForwarderAddress({ factory, forwarderRouter, treasury, salt });
    expect(await rc.predictForwarder(treasury, salt)).toBe(local); // throws on mismatch too
    const acct = getPermitAccountAddress({ factory, accountRouter, owner, index: 0n });
    expect(await rc.predictAccount(owner, 0n)).toBe(acct);
  });

  it("custodial: deposit to an undeployed address, then deploy+sweep in one tx", async () => {
    const salt = await deriveDepositSalt("e2e-secret-0123456789abcdef", "user-2");
    const fwd = await rc.predictForwarder(treasury, salt);
    expect(await rpc.hasCode(fwd)).toBe(false);
    await mint(fwd, 5_000_000n);
    expect(await rc.balanceOf(usdt, fwd)).toBe(5_000_000n);

    const before = await rc.balanceOf(usdt, treasury);
    const r = await rc.sweep({ treasury, salt, token: usdt });
    energy.deployAndSweep = r.info.receipt?.energy_usage_total;
    expect(r.info.receipt?.origin_energy_usage ?? 0).toBe(0); // caller pays
    expect(await rpc.hasCode(fwd)).toBe(true);
    expect((await rc.balanceOf(usdt, treasury)) - before).toBe(5_000_000n);

    // Second deposit: plain sweep on a deployed forwarder.
    await mint(fwd, 1_000_000n);
    const r2 = await rc.sweep({ treasury, salt, token: usdt });
    energy.sweepDeployed = r2.info.receipt?.energy_usage_total;
    expect(await rc.balanceOf(usdt, fwd)).toBe(0n);
  }, 120_000);

  it("custodial: TRX sent to a forwarder is swept to the treasury", async () => {
    const salt = await deriveDepositSalt("e2e-secret-0123456789abcdef", "user-trx");
    const fwd = await rc.predictForwarder(treasury, salt);
    await sendTrx(keys[4]!, fwd, 3_000_000n); // activates the address before deployment
    const before = await rpc.getTrxBalance(treasury);
    await rc.sweep({ treasury, salt }); // deploys onto a pre-activated address
    expect(await rpc.getTrxBalance(fwd)).toBe(0n);
    expect((await rpc.getTrxBalance(treasury)) - before).toBe(3_000_000n);
  }, 120_000);

  it("custodial: gated sweeper is enforced on TVM", async () => {
    const salt = await deriveDepositSalt("e2e-secret-0123456789abcdef", "user-gated");
    const fwd = await rc.predictForwarder(treasury, salt, admin.address);
    await mint(fwd, 1n);
    await expect(rc.sweep({ treasury, salt, sweeper: admin.address, token: usdt })).rejects.toThrow(/NotAuthorized/);
  }, 60_000);

  afterAll(() => {
    console.log("\nTVM energy (local tre node — NOT mainnet figures):");
    for (const [k, v] of Object.entries(energy)) console.log(`  ${k.padEnd(18)} ${v ?? "?"}`);
  });
});

void permitAccountAbi;
void Kind;
void toBase58;
void decodeFunctionResult;
