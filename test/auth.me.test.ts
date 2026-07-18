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

async function registerAndToken() {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
  return res.json().tokens.accessToken as string;
}

test("GET /me without token returns 401", async () => {
  const res = await app.inject({ method: "GET", url: "/me" });
  expect(res.statusCode).toBe(401);
});

test("GET /me with token returns the current user", async () => {
  const token = await registerAndToken();
  const res = await app.inject({
    method: "GET",
    url: "/me",
    headers: { authorization: `Bearer ${token}` },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().user.username).toBe("pingu");
  expect(res.json().user).not.toHaveProperty("password_hash");
});

test("PATCH /me updates the signature", async () => {
  const token = await registerAndToken();
  const res = await app.inject({
    method: "PATCH",
    url: "/me",
    headers: { authorization: `Bearer ${token}` },
    payload: { signature: "Noot noot" },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().user.signature).toBe("Noot noot");
});
