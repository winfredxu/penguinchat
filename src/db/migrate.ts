import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Pool } from "pg";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "migrations");

export async function runMigrations(pool: Pool): Promise<void> {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
       name text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )`
  );
  const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
  for (const file of files) {
    const done = await pool.query("SELECT 1 FROM schema_migrations WHERE name = $1", [file]);
    if (done.rowCount) continue;
    const sql = readFileSync(join(migrationsDir, file), "utf8");
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
      await client.query("COMMIT");
    } catch (e) {
      await client.query("ROLLBACK");
      throw e;
    } finally {
      client.release();
    }
  }
}

// Allow `npm run migrate` to run this directly.
if (process.argv[1] && process.argv[1].endsWith("migrate.ts")) {
  const { Pool } = await import("pg");
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  await runMigrations(pool);
  await pool.end();
  console.log("migrations applied");
}
