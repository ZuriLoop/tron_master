import { describe, expect, it } from "vitest";
import { main } from "../src/cli.js";
import { encodeConstructor, validateFactoryConfig } from "../src/deploy.js";

const good = {
  feeToken: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t",
  feeRecipient: "0x1111111111111111111111111111111111111111",
  maxBps: 50,
  maxCap: 1_000_000n,
  bps: 10,
  cap: 250_000n,
  admin: "0x2222222222222222222222222222222222222222",
  guardian: "0x3333333333333333333333333333333333333333",
  upgradeDelay: 3n * 86400n,
  pauseDuration: 7n * 86400n,
};

describe("factory config validation (mirrors the constructor)", () => {
  it("accepts a sane config and encodes it", () => {
    expect(validateFactoryConfig(good)).toEqual([]);
    expect(encodeConstructor(good)).toMatch(/^0x[0-9a-f]{640}$/);
  });
  it("rejects each invalid field", () => {
    expect(validateFactoryConfig({ ...good, upgradeDelay: 3600n })).toHaveLength(1);
    expect(validateFactoryConfig({ ...good, pauseDuration: 15n * 86400n })).toHaveLength(1);
    expect(validateFactoryConfig({ ...good, bps: 60 })).toHaveLength(1);
    expect(validateFactoryConfig({ ...good, guardian: good.admin })).toHaveLength(1);
    expect(validateFactoryConfig({ ...good, feeRecipient: "0x0000000000000000000000000000000000000000" })).toHaveLength(1);
    expect(validateFactoryConfig({ ...good, maxCap: 0n, cap: 0n })).toHaveLength(1);
  });
});

describe("cli", () => {
  it("prints help and version", async () => {
    expect(await main(["--version"])).toBe(0);
    expect(await main(["help"])).toBe(0);
  });
  it("rejects unknown commands and flags", async () => {
    expect(await main(["nope"])).toBe(2);
    expect(await main(["info", "--private-key", "x"])).toBe(2);
  });
  it("refuses mainnet writes without --yes before touching the network", async () => {
    expect(await main(["sweep", "--network", "mainnet", "--factory", good.admin, "--treasury", good.admin, "--salt", `0x${"00".repeat(32)}`])).toBe(2);
  });
});
