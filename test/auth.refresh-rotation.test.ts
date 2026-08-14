import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import jwt from "jsonwebtoken";
import { makeApp, makePool, testConfig } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;
beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => {
  await resetDb(pool);
  app = await makeApp(pool);
});
afterAll(async () => { await app.close(); await pool.end(); });

async function register(username: string) {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  return res.json() as { user: { id: string }; tokens: { accessToken: string; refreshToken: string } };
}

async function refresh(refreshToken: string) {
  return app.inject({ method: "POST", url: "/auth/refresh", payload: { refreshToken } });
}

async function revoked(jti: string): Promise<boolean | null> {
  const res = await pool.query("SELECT revoked FROM refresh_tokens WHERE jti = $1", [jti]);
  return res.rows[0]?.revoked ?? null;
}

function jtiOf(refreshToken: string): string {
  return (jwt.decode(refreshToken) as { jti: string }).jti;
}

test("register persists a non-revoked refresh token (FU-1)", async () => {
  const { tokens } = await register("alice");
  expect(await revoked(jtiOf(tokens.refreshToken))).toBe(false);
});

test("refresh rotates: returns a new refresh token and revokes the old (FU-1)", async () => {
  const { tokens } = await register("alice");
  const oldJti = jtiOf(tokens.refreshToken);
  const res = await refresh(tokens.refreshToken);
  expect(res.statusCode).toBe(200);
  const next = res.json().tokens;
  expect(next.refreshToken).not.toBe(tokens.refreshToken);
  expect(next.accessToken).toBeTruthy();
  expect(await revoked(oldJti)).toBe(true);
  expect(await revoked(jtiOf(next.refreshToken))).toBe(false);
});

test("reusing a rotated refresh token is rejected and revokes all the user's tokens (FU-1)", async () => {
  const { tokens } = await register("alice");
  const oldJti = jtiOf(tokens.refreshToken);
  // First refresh rotates -> oldJti revoked, a new jti issued.
  const r1 = await refresh(tokens.refreshToken);
  const newJti = jtiOf(r1.json().tokens.refreshToken);
  // Reusing the old (now revoked) token must be rejected AND revoke the new one
  // (assume compromise -> revoke every device).
  const r2 = await refresh(tokens.refreshToken);
  expect(r2.statusCode).toBe(401);
  expect(await revoked(newJti)).toBe(true);
  expect(await revoked(oldJti)).toBe(true);
});

test("a refresh token cannot be used as an access token (FU-7)", async () => {
  const { tokens } = await register("alice");
  const res = await app.inject({
    method: "GET",
    url: "/me",
    headers: { authorization: `Bearer ${tokens.refreshToken}` },
  });
  expect(res.statusCode).toBe(401);
});

test("an access token cannot be used as a refresh token (FU-7)", async () => {
  const { tokens } = await register("alice");
  const res = await refresh(tokens.accessToken);
  expect(res.statusCode).toBe(401);
});

test("a wrong-type token is rejected even when signed with the right secret (FU-7 type claim)", async () => {
  // Refresh-type payload signed with the ACCESS secret: signature verifies, but
  // verifyAccess must reject it because the type claim is not "access".
  const bad = jwt.sign({ sub: "x", type: "refresh" }, testConfig.jwtAccessSecret, { expiresIn: "15m" });
  const res = await app.inject({
    method: "GET",
    url: "/me",
    headers: { authorization: `Bearer ${bad}` },
  });
  expect(res.statusCode).toBe(401);
});

test("a tampered refresh token is rejected", async () => {
  const { tokens } = await register("alice");
  const res = await refresh(tokens.refreshToken + "x");
  expect(res.statusCode).toBe(401);
});
