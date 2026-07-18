import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    fileParallelism: false, // tests share one Postgres; run files serially
    hookTimeout: 30000,
    testTimeout: 20000,
  },
});
