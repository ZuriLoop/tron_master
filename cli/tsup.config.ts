import { defineConfig } from "tsup";

export default defineConfig({
  entry: ["src/bin.ts", "src/index.ts"],
  format: ["esm"],
  dts: { entry: "src/index.ts" },
  sourcemap: true,
  clean: true,
  platform: "node",
  target: "node20",
  external: ["@tron-paymaster/sdk", "viem"],
});
