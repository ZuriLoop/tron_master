import {
  ZERO_ADDRESS,
  type Hex,
  type TronRpc,
  type TronSigner,
  paymasterFactoryAbi,
  parseTronAddress,
  signTransaction,
} from "@tron-paymaster/sdk";
import { concat, encodeAbiParameters } from "viem";
import { paymasterFactoryArtifact } from "./artifacts.js";

export interface FactoryConfig {
  feeToken: string;
  feeRecipient: string;
  maxBps: number;
  maxCap: bigint;
  bps: number;
  cap: bigint;
  admin: string;
  guardian: string;
  upgradeDelay: bigint;
  pauseDuration: bigint;
}


/** Mirrors the constructor checks so mistakes fail before paying for a deploy. */
export function validateFactoryConfig(c: FactoryConfig): string[] {
  const errs: string[] = [];
  if (parseTronAddress(c.admin) === ZERO_ADDRESS) errs.push("admin is required");
  if (parseTronAddress(c.guardian) === ZERO_ADDRESS) errs.push("guardian is required");
  if (c.upgradeDelay < 2n * 86400n || c.upgradeDelay > 30n * 86400n) errs.push("upgrade delay must be 2–30 days");
  if (c.pauseDuration === 0n || c.pauseDuration > 14n * 86400n) errs.push("pause duration must be 1s–14 days");
  if (c.maxBps > 10_000 || c.bps > c.maxBps || c.cap > c.maxCap) errs.push("fee must satisfy bps <= maxBps <= 10000 and cap <= maxCap");
  const charges = c.maxBps !== 0 && c.maxCap !== 0n;
  if (charges && (parseTronAddress(c.feeToken) === ZERO_ADDRESS || parseTronAddress(c.feeRecipient) === ZERO_ADDRESS)) {
    errs.push("fee token and fee recipient are required when fees are enabled");
  }
  if (!charges && (c.maxBps !== 0 || c.maxCap !== 0n)) errs.push("set both maxBps and maxCap, or neither");
  if (parseTronAddress(c.admin) === parseTronAddress(c.guardian)) errs.push("admin and guardian should be different accounts");
  return errs;
}

export function encodeConstructor(c: FactoryConfig): Hex {
  const ctor = paymasterFactoryAbi.find((x) => x.type === "constructor");
  if (!ctor || ctor.type !== "constructor") throw new Error("constructor ABI missing");
  return encodeAbiParameters(ctor.inputs, [
    {
      feeToken: parseTronAddress(c.feeToken),
      feeRecipient: parseTronAddress(c.feeRecipient),
      maxBps: c.maxBps,
      maxCap: c.maxCap,
      bps: c.bps,
      cap: c.cap,
      admin: parseTronAddress(c.admin),
      guardian: parseTronAddress(c.guardian),
      upgradeDelay: c.upgradeDelay,
      pauseDuration: c.pauseDuration,
    },
  ]);
}

/**
 * Deploys a PaymasterFactory. `consume_user_resource_percent = 100` so every
 * caller pays its own energy (the deployer never subsidizes calls).
 */
export async function deployFactory(rpc: TronRpc, signer: TronSigner, c: FactoryConfig, feeLimit: bigint) {
  const errs = validateFactoryConfig(c);
  if (errs.length) throw new Error(`invalid factory config:\n  - ${errs.join("\n  - ")}`);
  const bytecode = concat([paymasterFactoryArtifact.bytecode as Hex, encodeConstructor(c)]);
  const maxFeeLimit = await rpc.getMaxFeeLimit();
  if (feeLimit > maxFeeLimit) feeLimit = maxFeeLimit;
  const tx = await rpc.buildDeployTransaction({
    from: signer.address,
    bytecode,
    abi: paymasterFactoryAbi,
    name: "PaymasterFactory",
    feeLimit,
    consumeUserResourcePercent: 100,
    originEnergyLimit: 10_000_000,
  });
  const signed = await signTransaction(tx, signer, {
    type: "CreateSmartContract",
    from: signer.address,
    bytecode,
    consumeUserResourcePercent: 100,
    maxFeeLimit: feeLimit,
    maxExpiryMs: rpc.maxTxExpiryMs,
  });
  const txid = await rpc.broadcast(signed);
  const info = await rpc.waitForTransaction(txid, { timeoutMs: 180_000 });
  const address = info.contract_address ?? tx.contract_address;
  if (!address) throw new Error(`deployed in ${txid} but no contract address returned`);
  return { txid, address: parseTronAddress(address), info };
}
