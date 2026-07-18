import { afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";

const pool = makePool();
const app = makeApp(pool);

afterAll(async () => {
  await app.close();
  await pool.end();
});

test("GET /health returns ok", async () => {
  const res = await app.inject({ method: "GET", url: "/health" });
  expect(res.statusCode).toBe(200);
  expect(res.json()).toEqual({ status: "ok" });
});
