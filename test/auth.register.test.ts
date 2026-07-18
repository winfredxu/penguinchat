import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => {
  await runMigrations(pool);
});
beforeEach(async () => {
  await resetDb(pool);
});
afterAll(async () => {
  await app.close();
  await pool.end();
});

test("register creates a user and returns tokens without password_hash", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
  expect(res.statusCode).toBe(201);
  const body = res.json();
  expect(body.user.username).toBe("pingu");
  expect(body.user).not.toHaveProperty("password_hash");
  expect(body.tokens.accessToken).toBeTruthy();
  expect(body.tokens.refreshToken).toBeTruthy();
});

test("duplicate username is rejected with 409", async () => {
  const payload = { username: "pingu", display_name: "Pingu", password: "noot123" };
  await app.inject({ method: "POST", url: "/auth/register", payload });
  const res = await app.inject({ method: "POST", url: "/auth/register", payload });
  expect(res.statusCode).toBe(409);
  expect(res.json().error).toBe("username_taken");
});

test("invalid payload is rejected with 400", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "x", display_name: "", password: "1" },
  });
  expect(res.statusCode).toBe(400);
});
