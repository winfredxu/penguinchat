import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await app.close(); await pool.end(); });

async function register(username: string) {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  const body = res.json();
  return { id: body.user.id as string, token: body.tokens.accessToken as string };
}
function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

test("full friend flow: request -> incoming -> accept -> contacts", async () => {
  const a = await register("alice");
  const b = await register("bob");

  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob", message: "hi" },
  });
  expect(send.statusCode).toBe(201);
  const requestId = send.json().request.id;

  const incoming = await app.inject({
    method: "GET",
    url: "/friend-requests",
    headers: auth(b.token),
  });
  expect(incoming.json()).toHaveLength(1);

  const accept = await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: auth(b.token),
  });
  expect(accept.statusCode).toBe(200);

  const aContacts = await app.inject({ method: "GET", url: "/contacts", headers: auth(a.token) });
  const bContacts = await app.inject({ method: "GET", url: "/contacts", headers: auth(b.token) });
  expect(aContacts.json().map((c: any) => c.username)).toEqual(["bob"]);
  expect(bContacts.json().map((c: any) => c.username)).toEqual(["alice"]);
  expect(aContacts.json()[0].presence).toBe("offline");
});

test("cannot friend-request a nonexistent user", async () => {
  const a = await register("alice");
  const res = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "ghost" },
  });
  expect(res.statusCode).toBe(404);
});

test("duplicate pending request is rejected", async () => {
  const a = await register("alice");
  await register("bob");
  const payload = { username: "bob" };
  await app.inject({ method: "POST", url: "/friend-requests", headers: auth(a.token), payload });
  const res = await app.inject({ method: "POST", url: "/friend-requests", headers: auth(a.token), payload });
  expect(res.statusCode).toBe(409);
});

test("cannot accept someone else's request", async () => {
  const a = await register("alice");
  await register("bob");
  const carol = await register("carol");
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob" },
  });
  const requestId = send.json().request.id;
  const res = await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: auth(carol.token),
  });
  expect(res.statusCode).toBe(403);
});

test("decline removes the request from incoming", async () => {
  const a = await register("alice");
  const b = await register("bob");
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob" },
  });
  const requestId = send.json().request.id;
  await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/decline`,
    headers: auth(b.token),
  });
  const incoming = await app.inject({ method: "GET", url: "/friend-requests", headers: auth(b.token) });
  expect(incoming.json()).toHaveLength(0);
});
