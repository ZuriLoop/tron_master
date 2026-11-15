import { type TronAddress, ZERO_ADDRESS, parseTronAddress } from "@tron-paymaster/sdk";
import { describe, expect, it } from "vitest";
import { type GovernanceSnapshot, diffGovernance } from "../src/watcher.js";

const a = (n: number) => parseTronAddress(`0x${n.toString(16).padStart(40, "0")}`);
const FACTORY = a(0xf);
const NOW = 1_800_000_000n;
const DAY = 86_400n;

function snap(over: Partial<GovernanceSnapshot> = {}): GovernanceSnapshot {
  return {
    implementation: { forwarder: a(1), account: a(2) },
    pendingUpgrade: { forwarder: { implementation: ZERO_ADDRESS, eta: 0n }, account: { implementation: ZERO_ADDRESS, eta: 0n } },
    admin: a(10),
    guardian: a(11),
    pendingRoles: { admin: ZERO_ADDRESS, guardian: ZERO_ADDRESS, eta: 0n },
    paused: false,
    pausedUntil: 0n,
    bps: 10,
    cap: 500_000n,
    now: NOW,
    ...over,
  };
}
const kinds = (prev: GovernanceSnapshot | undefined, next: GovernanceSnapshot) => diffGovernance(FACTORY, prev, next).map((x) => `${x.kind}:${x.severity}`);
const queuedAccount = (impl: TronAddress, eta: bigint) => ({
  pendingUpgrade: { forwarder: { implementation: ZERO_ADDRESS, eta: 0n }, account: { implementation: impl, eta } },
});

describe("diffGovernance", () => {
  it("quiet state produces no alerts, on first poll or later", () => {
    expect(kinds(undefined, snap())).toEqual([]);
    expect(kinds(snap(), snap({ now: NOW + 60n }))).toEqual([]);
  });

  it("reports what is already pending on the first poll", () => {
    expect(kinds(undefined, snap({ ...queuedAccount(a(3), NOW + 2n * DAY), paused: true, pausedUntil: NOW + 3600n }))).toEqual([
      "UpgradeQueued:critical",
      "Paused:warning",
    ]);
  });

  it("upgrade lifecycle: queued once, executable once, executed", () => {
    const q = snap(queuedAccount(a(3), NOW + 2n * DAY));
    const qa = diffGovernance(FACTORY, snap(), q);
    expect(qa).toHaveLength(1);
    expect(qa[0]).toMatchObject({ kind: "UpgradeQueued", severity: "critical", details: { kind: "account", implementation: a(3), current: a(2) } });
    expect(qa[0]!.message).toMatch(/in 48.0h/);
    // No repeat while unchanged.
    expect(kinds(q, { ...q, now: NOW + DAY })).toEqual([]);
    // Crossing the eta fires once.
    const due = { ...q, now: NOW + 2n * DAY };
    expect(kinds({ ...q, now: NOW + DAY }, due)).toEqual(["UpgradeExecutable:critical"]);
    expect(kinds(due, { ...due, now: due.now + 60n })).toEqual([]);
    // Executed: implementation changed to the queued one -> warning, not critical.
    const done = snap({ implementation: { forwarder: a(1), account: a(3) }, now: due.now + 120n });
    expect(kinds(due, done)).toEqual(["Upgraded:warning"]);
  });

  it("an implementation change that was never seen queued is critical", () => {
    expect(kinds(snap(), snap({ implementation: { forwarder: a(9), account: a(2) } }))).toEqual(["Upgraded:critical"]);
  });

  it("cancel and re-queue", () => {
    const q = snap(queuedAccount(a(3), NOW + 2n * DAY));
    expect(kinds(q, snap())).toEqual(["UpgradeCancelled:info"]);
    // A cancel-and-requeue inside one poll reports both facts.
    const q2 = snap(queuedAccount(a(4), NOW + 3n * DAY));
    expect(kinds(q, q2)).toEqual(["UpgradeQueued:critical", "UpgradeCancelled:info"]);
  });

  it("role changes: queued (critical, not vetoable), executable, executed, cancelled", () => {
    const r = snap({ pendingRoles: { admin: a(20), guardian: a(21), eta: NOW + 2n * DAY } });
    const al = diffGovernance(FACTORY, snap(), r);
    expect(al.map((x) => x.kind)).toEqual(["RolesQueued"]);
    expect(al[0]!.message).toMatch(/cannot veto/);
    expect(kinds({ ...r, now: NOW + DAY }, { ...r, now: NOW + 2n * DAY })).toEqual(["RolesExecutable:critical"]);
    expect(kinds(r, snap({ admin: a(20), guardian: a(21) }))).toEqual(["RolesUpdated:warning"]);
    expect(kinds(r, snap())).toEqual(["RolesCancelled:info"]);
  });

  it("pause, extended pause, unpause", () => {
    const p = snap({ paused: true, pausedUntil: NOW + 3600n });
    expect(kinds(snap(), p)).toEqual(["Paused:warning"]);
    expect(kinds(p, { ...p, now: NOW + 60n })).toEqual([]);
    expect(kinds(p, snap({ paused: true, pausedUntil: NOW + 7200n }))).toEqual(["Paused:warning"]);
    expect(kinds(p, snap())).toEqual(["Unpaused:info"]);
  });

  it("fee raises warn, fee cuts inform", () => {
    expect(kinds(snap(), snap({ bps: 20 }))).toEqual(["ProtocolFeeUpdated:warning"]);
    expect(kinds(snap(), snap({ cap: 1_000_000n }))).toEqual(["ProtocolFeeUpdated:warning"]);
    expect(kinds(snap(), snap({ bps: 5 }))).toEqual(["ProtocolFeeUpdated:info"]);
  });

  it("dedupe keys are stable per fact", () => {
    const q = snap(queuedAccount(a(3), NOW + 2n * DAY));
    const k1 = diffGovernance(FACTORY, undefined, q)[0]!.key;
    const k2 = diffGovernance(FACTORY, snap(), { ...q, now: NOW + 5n })[0]!.key;
    expect(k1).toBe(k2);
    expect(k1).toContain(FACTORY);
  });
});
