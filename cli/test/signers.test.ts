/**
 * Which key signs is a question with one correct answer at a time. These
 * tests are mostly about the wrong answers being refused loudly.
 */
import { parseTronAddress, turnkeyTronSigner } from "@tron-paymaster/sdk";
import { keccak256, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { describe, expect, it } from "vitest";
import { SIGNER_ENV, resolveSigner } from "../src/signers.js";

const KEY = keccak256(toHex("signer-test"));
const ADDRESS = privateKeyToAccount(KEY).address;
const TURNKEY_ADDRESS = "TAyW6Fd5pStEQMjmzfT7PBPPkrVjUJrYrJ";

const turnkeyEnv = {
  [SIGNER_ENV.kind]: "turnkey",
  [SIGNER_ENV.address]: TURNKEY_ADDRESS,
  [SIGNER_ENV.turnkeyOrg]: "org-1",
  [SIGNER_ENV.turnkeyPublicKey]: "pub",
  [SIGNER_ENV.turnkeyPrivateKey]: "priv",
};

describe("private key signer", () => {
  it("is the default, and accepts a key with or without 0x", () => {
    expect(resolveSigner({ [SIGNER_ENV.key]: KEY }).address).toBe(parseTronAddress(ADDRESS));
    expect(resolveSigner({ [SIGNER_ENV.key]: KEY.slice(2) }).address).toBe(parseTronAddress(ADDRESS));
  });

  it("says which variable to set when there is no key", () => {
    expect(() => resolveSigner({})).toThrow(/set TRON_PRIVATE_KEY \(hex private key\)/);
  });

  it("refuses a key that is not 32 bytes", () => {
    expect(() => resolveSigner({ [SIGNER_ENV.key]: "0xdeadbeef" })).toThrow(/32-byte hex key/);
  });
});

describe("turnkey signer", () => {
  it("knows its address without talking to anyone", () => {
    // The address is configuration, which is what keeps signer() synchronous.
    expect(resolveSigner(turnkeyEnv).address).toBe(parseTronAddress(TURNKEY_ADDRESS));
  });

  it("names the variable that is missing", () => {
    for (const missing of [SIGNER_ENV.address, SIGNER_ENV.turnkeyOrg, SIGNER_ENV.turnkeyPublicKey, SIGNER_ENV.turnkeyPrivateKey]) {
      const env = { ...turnkeyEnv };
      delete (env as Record<string, string>)[missing];
      expect(() => resolveSigner(env), missing).toThrow(new RegExp(`set ${missing} `));
    }
  });

  it("refuses to guess when a private key is also set", () => {
    // Two possible signers for the same money movement is not a warning.
    expect(() => resolveSigner({ ...turnkeyEnv, [SIGNER_ENV.key]: KEY })).toThrow(/unambiguous which key signs/);
  });

  it("rejects an unknown signer kind", () => {
    expect(() => resolveSigner({ [SIGNER_ENV.kind]: "hsm" })).toThrow(/must be "key" or "turnkey"/);
  });
});

describe("the Turnkey adapter the CLI wraps", () => {
  it("asks Turnkey to sign the raw transaction, against the configured account", async () => {
    const seen: Array<Record<string, unknown>> = [];
    const signer = turnkeyTronSigner({
      address: TURNKEY_ADDRESS,
      organizationId: "org-1",
      api: {
        async signTransaction(input) {
          seen.push(input);
          return { signedTransaction: "0xsigned" };
        },
        async signRawPayload() {
          throw new Error("not used for Tron transactions");
        },
      },
    });

    const out = await signer.signRawTransaction!({ txID: "ab".repeat(32), raw_data_hex: "0a02beef" } as never);
    expect(out).toBe("0xsigned");
    expect(seen).toEqual([
      {
        signWith: TURNKEY_ADDRESS,
        unsignedTransaction: "0a02beef",
        type: "TRANSACTION_TYPE_TRON",
        organizationId: "org-1",
      },
    ]);
    // Turnkey is sent the protobuf, not a JSON description of it: that is what
    // lets a policy pin the contract, the selector and the arguments.
    expect(seen[0]!.unsignedTransaction).toBe("0a02beef");
  });
});
