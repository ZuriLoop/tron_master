// Compiles src/ with TRON's solc fork (the compiler whose output is deployed
// and verified on Tronscan). Foundry uses upstream solc for tests only.
//
// The compiler is the release's soljson.js, pinned by sha256, so builds are
// reproducible on any OS. Output: out-tron/<Contract>.json plus
// out-tron/build-info.json (the exact standard-JSON input, for verification).

import { createHash } from "node:crypto";
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync, existsSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const wrapper = require("solc/wrapper");

export const TRON_SOLC = {
  version: "0.8.26",
  tag: "tv_0.8.26",
  url: "https://github.com/tronprotocol/solidity/releases/download/tv_0.8.26/soljson.js",
  sha256: "31fe546b9e6ad74e816d6406dcdb59f3af180f9c1145fd994bd5205d9c8465c1",
};

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const CACHE = join(ROOT, "cache", "tron-solc", TRON_SOLC.version);
const OUT = join(ROOT, "out-tron");
const REMAPPINGS = [["@openzeppelin/tron-contracts/", "lib/oz-tron/contracts/"]];

export const SETTINGS = {
  evmVersion: "cancun",
  optimizer: { enabled: true, runs: 10000 },
  viaIR: false,
  metadata: { bytecodeHash: "none" },
  remappings: REMAPPINGS.map(([from, to]) => `${from}=${to}`),
  outputSelection: {
    "*": { "*": ["abi", "evm.bytecode.object", "evm.deployedBytecode.object", "storageLayout"] },
  },
};

const sha256 = (buf) => createHash("sha256").update(buf).digest("hex");

async function loadCompiler() {
  const file = join(CACHE, "soljson.cjs");
  if (!existsSync(file)) {
    mkdirSync(CACHE, { recursive: true });
    console.log(`downloading ${TRON_SOLC.url}`);
    const res = await fetch(TRON_SOLC.url);
    if (!res.ok) throw new Error(`download failed: ${res.status}`);
    writeFileSync(file, Buffer.from(await res.arrayBuffer()));
  }
  const got = sha256(readFileSync(file));
  if (got !== TRON_SOLC.sha256) {
    throw new Error(`soljson.js sha256 mismatch: got ${got}, want ${TRON_SOLC.sha256}. Delete ${file} and retry.`);
  }
  return wrapper(require(file));
}

function walk(dir) {
  return readdirSync(dir).flatMap((name) => {
    const p = join(dir, name);
    return statSync(p).isDirectory() ? walk(p) : p.endsWith(".sol") ? [p] : [];
  });
}

function resolveImport(path) {
  for (const [from, to] of REMAPPINGS) if (path.startsWith(from)) return join(ROOT, to, path.slice(from.length));
  return join(ROOT, path);
}

const WITH_MOCKS = process.argv.includes("--with-mocks");

export function buildInput({ withMocks = WITH_MOCKS } = {}) {
  const sources = {};
  const files = walk(join(ROOT, "src"));
  if (withMocks) files.push(...walk(join(ROOT, "test", "foundry", "mocks")));
  for (const file of files) {
    sources[relative(ROOT, file)] = { content: readFileSync(file, "utf8") };
  }
  return { language: "Solidity", sources, settings: SETTINGS };
}

async function main() {
  const solc = await loadCompiler();
  const version = solc.version();
  const input = buildInput();
  const missing = [];
  const output = JSON.parse(
    solc.compile(JSON.stringify(input), {
      import: (path) => {
        const file = resolveImport(path);
        if (!existsSync(file)) {
          missing.push(path);
          return { error: `not found: ${path}` };
        }
        return { contents: readFileSync(file, "utf8") };
      },
    }),
  );

  const errors = (output.errors ?? []).filter((e) => e.severity === "error");
  for (const e of output.errors ?? []) if (e.severity !== "error") console.warn(e.formattedMessage.trim());
  if (errors.length || missing.length) {
    for (const e of errors) console.error(e.formattedMessage);
    throw new Error(`compilation failed (${errors.length} errors, missing: ${missing.join(", ") || "none"})`);
  }

  mkdirSync(OUT, { recursive: true });
  const summary = [];
  for (const [source, contracts] of Object.entries(output.contracts ?? {})) {
    if (!source.startsWith("src/") && !(WITH_MOCKS && source.startsWith("test/"))) continue;
    for (const [name, c] of Object.entries(contracts)) {
      const bytecode = c.evm.bytecode.object;
      if (!bytecode) continue; // interfaces / libraries without code
      const artifact = {
        contractName: name,
        sourceName: source,
        compiler: { name: "tron-solc", version, ...TRON_SOLC },
        abi: c.abi,
        bytecode: `0x${bytecode}`,
        deployedBytecode: `0x${c.evm.deployedBytecode.object}`,
        storageLayout: c.storageLayout,
      };
      writeFileSync(join(OUT, `${name}.json`), `${JSON.stringify(artifact, null, 2)}\n`);
      summary.push([name, c.evm.deployedBytecode.object.length / 2, bytecode.length / 2]);
    }
  }
  if (!WITH_MOCKS) writeFileSync(join(OUT, "build-info.json"), `${JSON.stringify({ solcVersion: version, input }, null, 2)}\n`);

  console.log(`tron-solc ${version}`);
  for (const [name, runtime, init] of summary) console.log(`  ${name.padEnd(22)} runtime ${runtime} B  init ${init} B`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main().catch((e) => {
    console.error(e.message);
    process.exit(1);
  });
}
