import { beforeAll, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;

beforeAll(async () => {
  app = await makeApp(pool);
});

afterAll(async () => {
  await app.close();
  await pool.end();
});

test("GET /health returns ok", async () => {
  const res = await app.inject({ method: "GET", url: "/health" });
  expect(res.statusCode).toBe(200);
  expect(res.json()).toEqual({ status: "ok" });
});

test("malformed JSON is reported as a client error", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/login",
    headers: { "content-type": "application/json" },
    payload: "",
  });
  expect(res.statusCode).toBe(400);
  expect(res.json()).toMatchObject({ error: "invalid_request" });
});
