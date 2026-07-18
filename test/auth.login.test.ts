import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;

beforeAll(async () => {
  await runMigrations(pool);
  app = await makeApp(pool);
});
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await app.close(); await pool.end(); });

async function makeUser() {
  return app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
}

test("login with correct credentials returns tokens", async () => {
  await makeUser();
  const res = await app.inject({
    method: "POST",
    url: "/auth/login",
    payload: { username: "pingu", password: "noot123" },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().tokens.accessToken).toBeTruthy();
});

test("login with wrong password returns 401", async () => {
  await makeUser();
  const res = await app.inject({
    method: "POST",
    url: "/auth/login",
    payload: { username: "pingu", password: "wrong" },
  });
  expect(res.statusCode).toBe(401);
  expect(res.json().error).toBe("invalid_credentials");
});

test("refresh returns a fresh token pair", async () => {
  const reg = (await makeUser()).json();
  const res = await app.inject({
    method: "POST",
    url: "/auth/refresh",
    payload: { refreshToken: reg.tokens.refreshToken },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().tokens.accessToken).toBeTruthy();
  expect(res.json().tokens.refreshToken).toBeTruthy();
});

test("refresh with garbage token returns 401", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/refresh",
    payload: { refreshToken: "not-a-jwt" },
  });
  expect(res.statusCode).toBe(401);
});
