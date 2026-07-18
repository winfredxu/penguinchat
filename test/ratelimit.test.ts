import { beforeAll, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;

beforeAll(async () => {
  await runMigrations(pool);
  app = await makeApp(pool);
});
afterAll(async () => { await app.close(); await pool.end(); });

test("health endpoint responds and sets rate-limit headers", async () => {
  const res = await app.inject({ method: "GET", url: "/health" });
  expect(res.statusCode).toBe(200);
  expect(res.headers["x-ratelimit-limit"]).toBeDefined();
});
