import { Pool } from "pg";
import { buildApp } from "../../src/app.js";

const TEST_DB_URL =
  process.env.DATABASE_URL ??
  "postgres://penguin:penguin@localhost:5432/penguinchat";

export function makePool(): Pool {
  return new Pool({ connectionString: TEST_DB_URL });
}

export function makeApp(pool: Pool) {
  return buildApp({ pool });
}
