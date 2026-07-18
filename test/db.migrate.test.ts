import { beforeAll, afterAll, expect, test } from "vitest";
import { conversationId } from "../src/lib/ids.js";
import { runMigrations } from "../src/db/migrate.js";
import { makePool } from "./helpers/app.js";

test("conversationId is order-independent and stable", () => {
  const a = "11111111-1111-1111-1111-111111111111";
  const b = "22222222-2222-2222-2222-222222222222";
  expect(conversationId(a, b)).toBe(conversationId(b, a));
  expect(conversationId(a, b)).toMatch(/^[0-9a-f-]{36}$/);
});

const pool = makePool();

beforeAll(async () => {
  await runMigrations(pool);
});

afterAll(async () => {
  await pool.end();
});

test("migration creates expected tables", async () => {
  const res = await pool.query(
    `SELECT table_name FROM information_schema.tables
     WHERE table_schema = 'public' ORDER BY table_name`
  );
  const names = res.rows.map((r) => r.table_name);
  expect(names).toEqual(
    expect.arrayContaining([
      "friend_requests",
      "friendships",
      "messages",
      "schema_migrations",
      "users",
    ])
  );
});

test("runMigrations is idempotent", async () => {
  await runMigrations(pool); // second run should be a no-op
  const res = await pool.query("SELECT count(*) FROM schema_migrations");
  expect(Number(res.rows[0].count)).toBeGreaterThanOrEqual(1);
});
