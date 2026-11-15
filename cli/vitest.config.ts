import { fileURLToPath } from "node:url";
import { defineConfig } from "vitest/config";

export default defineConfig({
  resolve: {
    // Test against SDK source, never a stale build.
    alias: { "@tron-paymaster/sdk": fileURLToPath(new URL("../sdk/src/index.ts", import.meta.url)) },
  },
  test: { testTimeout: 120_000, hookTimeout: 300_000, fileParallelism: false },
});
