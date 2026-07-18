import { Pool } from "pg";
import { buildApp } from "../../src/app.js";
import type { Config } from "../../src/config.js";

const TEST_DB_URL =
  process.env.DATABASE_URL ??
  "postgres://penguin:penguin@localhost:5432/penguinchat";

export const testConfig: Config = {
  port: 0,
  databaseUrl: TEST_DB_URL,
  jwtAccessSecret: "test-access",
  jwtRefreshSecret: "test-refresh",
  accessTtl: "15m",
  refreshTtl: "30d",
};

export function makePool(): Pool {
  return new Pool({ connectionString: TEST_DB_URL });
}

export async function makeApp(pool: Pool) {
  return buildApp({ pool, config: testConfig });
}
