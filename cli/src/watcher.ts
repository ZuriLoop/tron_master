import { type PaymasterClient, type TronAddress, ZERO_ADDRESS } from "@tron-paymaster/sdk";
import { decodeFunctionResult, encodeFunctionData } from "viem";
import type { WebhookDispatcher } from "./webhooks.js";

/**
 * Governance watcher. Polls the factory's governance state and alerts on
 * every change that could affect user funds, so owners and integrators can
 * react (withdraw, veto, escalate) inside the timelock.
 *
 * It diffs state rather than reading event logs, so it works against any
 * java-tron node (the event API is TronGrid-only). Anything that can change
 * code or roles stays queued for at least UPGRADE_DELAY, far longer than the
 * poll interval, so nothing that matters can slip between polls. A pause that
 * starts and ends within one interval can be missed; that cannot move funds.
 */

export type Severity = "critical" | "warning" | "info";

export type AlertKind =
  | "UpgradeQueued"
  | "UpgradeExecutable"
  | "UpgradeCancelled"
  | "Upgraded"
  | "RolesQueued"
  | "RolesExecutable"
  | "RolesCancelled"
  | "RolesUpdated"
  | "Paused"
  | "Unpaused"
  | "ProtocolFeeUpdated";

export interface GovernanceAlert {
  kind: AlertKind;
  severity: Severity;
  factory: TronAddress;
  /** Human-readable one-liner. */
  message: string;
  /** Stable per fact, for deduplication across restarts and retries. */
  key: string;
  details: Record<string, unknown>;
}

const KINDS = ["forwarder", "account"] as const;
type KindName = (typeof KINDS)[number];

export interface GovernanceSnapshot {
  implementation: Record<KindName, TronAddress>;
  pendingUpgrade: Record<KindName, { implementation: TronAddress; eta: bigint }>;
  admin: TronAddress;
  guardian: TronAddress;
  pendingRoles: { admin: TronAddress; guardian: TronAddress; eta: bigint };
  paused: boolean;
  pausedUntil: bigint;
  bps: number;
  cap: bigint;
  /** Block time of the read, in seconds. */
  now: bigint;
}

export async function readGovernance(client: PaymasterClient): Promise<GovernanceSnapshot> {
  const [info, pf, pa, roles, block] = await Promise.all([
    client.getFactoryInfo(),
    client.getPendingUpgrade(0),
    client.getPendingUpgrade(1),
    client.getPendingRoles(),
    client.rpc.getNowBlock(),
  ]);
  return {
    implementation: { forwarder: info.forwarderImplementation, account: info.accountImplementation },
    pendingUpgrade: { forwarder: pf, account: pa },
    admin: info.admin,
    guardian: info.guardian,
    pendingRoles: roles,
    paused: info.paused,
    pausedUntil: info.pausedUntil,
    bps: info.bps,
    cap: info.cap,
    now: BigInt(Math.floor(block.timestamp / 1000)),
  };
}

const iso = (s: bigint) => new Date(Number(s) * 1000).toISOString();
const hours = (s: bigint) => `${(Number(s) / 3600).toFixed(1)}h`;

/**
 * Alerts implied by moving from `prev` to `next`. With `prev` undefined
 * (first poll) it reports everything currently pending or paused.
 */
export function diffGovernance(factory: TronAddress, prev: GovernanceSnapshot | undefined, next: GovernanceSnapshot): GovernanceAlert[] {
  const out: GovernanceAlert[] = [];
  const add = (kind: AlertKind, severity: Severity, key: string, message: string, details: Record<string, unknown>) =>
    out.push({ kind, severity, factory, message, key: `${factory}:${kind}:${key}`, details });

  for (const k of KINDS) {
    const p = prev?.pendingUpgrade[k];
    const n = next.pendingUpgrade[k];
    const queued = n.implementation !== ZERO_ADDRESS;
    const wasQueued = p !== undefined && p.implementation !== ZERO_ADDRESS;
    const same = wasQueued && p.implementation === n.implementation && p.eta === n.eta;
    if (queued && !same) {
      add("UpgradeQueued", "critical", `${k}:${n.implementation}:${n.eta}`, `${k} upgrade to ${n.implementation} queued; executable at ${iso(n.eta)} (in ${hours(n.eta - next.now)}). Every ${k} will run the new code. Review it now; the guardian can veto.`, {
        kind: k,
        implementation: n.implementation,
        current: next.implementation[k],
        eta: n.eta,
      });
    }
    if (queued && next.now >= n.eta && (!same || prev!.now < n.eta)) {
      add("UpgradeExecutable", "critical", `${k}:${n.implementation}:${n.eta}`, `${k} upgrade to ${n.implementation} is executable now.`, {
        kind: k,
        implementation: n.implementation,
        eta: n.eta,
      });
    }
    const implChanged = prev !== undefined && prev.implementation[k] !== next.implementation[k];
    if (implChanged) {
      add("Upgraded", wasQueued && p.implementation === next.implementation[k] ? "warning" : "critical", `${k}:${next.implementation[k]}`, `${k} implementation changed ${prev.implementation[k]} -> ${next.implementation[k]}.`, {
        kind: k,
        from: prev.implementation[k],
        to: next.implementation[k],
      });
    } else if (wasQueued && !same) {
      // Covers both a plain cancel and a cancel-and-requeue within one poll
      // (the new queue alerts separately above).
      add("UpgradeCancelled", "info", `${k}:${p.implementation}:${p.eta}`, `${k} upgrade to ${p.implementation} was cancelled or replaced.`, { kind: k, implementation: p.implementation });
    }
  }

  const pr = prev?.pendingRoles;
  const nr = next.pendingRoles;
  const rolesQueued = nr.eta !== 0n;
  const rolesWasQueued = pr !== undefined && pr.eta !== 0n;
  const rolesSame = rolesWasQueued && pr.admin === nr.admin && pr.guardian === nr.guardian && pr.eta === nr.eta;
  if (rolesQueued && !rolesSame) {
    add("RolesQueued", "critical", `${nr.admin}:${nr.guardian}:${nr.eta}`, `role change queued: admin ${nr.admin}, guardian ${nr.guardian}; executable at ${iso(nr.eta)} (in ${hours(nr.eta - next.now)}). The guardian cannot veto a role change; only the current admin can cancel it.`, {
      admin: nr.admin,
      guardian: nr.guardian,
      currentAdmin: next.admin,
      currentGuardian: next.guardian,
      eta: nr.eta,
    });
  }
  if (rolesQueued && next.now >= nr.eta && (!rolesSame || prev!.now < nr.eta)) {
    add("RolesExecutable", "critical", `${nr.admin}:${nr.guardian}:${nr.eta}`, "queued role change is executable now.", { admin: nr.admin, guardian: nr.guardian });
  }
  const rolesChanged = prev !== undefined && (prev.admin !== next.admin || prev.guardian !== next.guardian);
  if (rolesChanged) {
    add("RolesUpdated", "warning", `${next.admin}:${next.guardian}`, `roles changed: admin ${next.admin}, guardian ${next.guardian}.`, {
      from: { admin: prev.admin, guardian: prev.guardian },
      to: { admin: next.admin, guardian: next.guardian },
    });
  } else if (rolesWasQueued && !rolesQueued) {
    add("RolesCancelled", "info", `${pr.admin}:${pr.guardian}:${pr.eta}`, "queued role change was cancelled.", {});
  }

  if (next.paused && (!prev?.paused || prev.pausedUntil !== next.pausedUntil)) {
    add("Paused", "warning", `${next.pausedUntil}`, `protocol paused until ${iso(next.pausedUntil)}: permits and sweeps revert; withdrawals still work.`, { until: next.pausedUntil });
  } else if (prev?.paused && !next.paused) {
    add("Unpaused", "info", `${prev.pausedUntil}:${next.now}`, "protocol unpaused.", {});
  }

  if (prev !== undefined && (prev.bps !== next.bps || prev.cap !== next.cap)) {
    const raised = next.bps > prev.bps || next.cap > prev.cap;
    add("ProtocolFeeUpdated", raised ? "warning" : "info", `${next.bps}:${next.cap}`, `protocol fee ${prev.bps} bps / cap ${prev.cap} -> ${next.bps} bps / cap ${next.cap}.`, {
      from: { bps: prev.bps, cap: prev.cap },
      to: { bps: next.bps, cap: next.cap },
    });
  }
  return out;
}

/** Checks a queued implementation: it must have code and report this factory as FACTORY(). */
export async function inspectImplementation(client: PaymasterClient, impl: TronAddress) {
  const hasCode = await client.rpc.hasCode(impl);
  let factoryMatches = false;
  if (hasCode) {
    try {
      const abi = [{ type: "function", name: "FACTORY", inputs: [], outputs: [{ type: "address" }], stateMutability: "view" }] as const;
      const { result } = await client.rpc.call({ to: impl, data: encodeFunctionData({ abi, functionName: "FACTORY" }) });
      const f = decodeFunctionResult({ abi, functionName: "FACTORY", data: result });
      factoryMatches = f.toLowerCase().slice(2) === client.factory.toLowerCase().slice(2);
    } catch {
      factoryMatches = false;
    }
  }
  return { hasCode, factoryMatches };
}

export interface WatcherOptions {
  client: PaymasterClient;
  intervalMs?: number;
  /** Implementations you have reviewed; any other queued implementation is flagged "unreviewed". */
  expectedImplementations?: TronAddress[];
  onAlert: (a: GovernanceAlert) => void;
  webhooks?: WebhookDispatcher;
  onError?: (e: Error) => void;
}

export function createGovernanceWatcher(opts: WatcherOptions) {
  let prev: GovernanceSnapshot | undefined;
  let timer: ReturnType<typeof setInterval> | undefined;
  const expected = new Set(opts.expectedImplementations ?? []);

  async function poll(): Promise<GovernanceAlert[]> {
    const next = await readGovernance(opts.client);
    const alerts = diffGovernance(opts.client.factory, prev, next);
    for (const a of alerts) {
      if (a.kind === "UpgradeQueued") {
        const impl = a.details.implementation as TronAddress;
        Object.assign(a.details, await inspectImplementation(opts.client, impl), { reviewed: expected.has(impl) });
        if (!a.details.hasCode || !a.details.factoryMatches) a.message += " WARNING: implementation has no code or a different FACTORY() (executeUpgrade would revert).";
        if (!expected.has(impl)) a.message += " Implementation is not in the reviewed list.";
      }
      opts.onAlert(a);
      opts.webhooks?.send({ type: "governance.alert", idempotencyKey: a.key, createdAt: Date.now(), data: a });
    }
    prev = next;
    return alerts;
  }

  return {
    poll,
    start() {
      const run = () => poll().catch((e: Error) => (opts.onError ?? (() => {}))(e));
      void run();
      timer = setInterval(run, opts.intervalMs ?? 60_000);
    },
    async stop() {
      if (timer) clearInterval(timer);
      await opts.webhooks?.drain();
    },
  };
}
