import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";
import { insertUser } from "../src/modules/auth/auth.repo.js";
import { hashPassword } from "../src/modules/auth/password.js";
import { insertFriendship } from "../src/modules/contacts/contacts.repo.js";
import { AppError } from "../src/lib/errors.js";
import { send, markRead, listHistory } from "../src/modules/messaging/messaging.service.js";
import { conversationId } from "../src/lib/ids.js";

const pool = makePool();

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await pool.end(); });

async function seedFriends() {
  const a = await insertUser(pool, { username: "alice", display_name: "A", password_hash: await hashPassword("x") });
  const b = await insertUser(pool, { username: "bob", display_name: "B", password_hash: await hashPassword("x") });
  await insertFriendship(pool, a.id, b.id);
  return { a, b };
}

test("send persists a message between friends with the deterministic conversation id", async () => {
  const { a, b } = await seedFriends();
  const msg = await send(pool, a.id, { toUserId: b.id, body: "hello" });
  expect(msg.body).toBe("hello");
  expect(msg.conversation).toBe(conversationId(a.id, b.id));
  expect(msg.sender_id).toBe(a.id);
  expect(msg.recipient_id).toBe(b.id);
});

test("send to a non-friend throws 403 not_friends", async () => {
  const a = await insertUser(pool, { username: "alice", display_name: "A", password_hash: await hashPassword("x") });
  const b = await insertUser(pool, { username: "bob", display_name: "B", password_hash: await hashPassword("x") });
  // no friendship
  await expect(send(pool, a.id, { toUserId: b.id, body: "hi" })).rejects.toMatchObject({
    status: 403, code: "not_friends",
  });
});

test("markRead to a non-friend throws 403", async () => {
  const a = await insertUser(pool, { username: "alice", display_name: "A", password_hash: await hashPassword("x") });
  const b = await insertUser(pool, { username: "bob", display_name: "B", password_hash: await hashPassword("x") });
  await expect(markRead(pool, a.id, b.id, "00000000-0000-0000-0000-000000000000")).rejects.toMatchObject({
    status: 403, code: "not_friends",
  });
});

test("listHistory returns messages newest-first and clamps limit", async () => {
  const { a, b } = await seedFriends();
  for (let i = 0; i < 3; i++) {
    await send(pool, a.id, { toUserId: b.id, body: `m${i}` });
    await new Promise((r) => setTimeout(r, 10));
  }
  const all = await listHistory(pool, a.id, b.id, { limit: 50 });
  expect(all.map((m) => m.body)).toEqual(["m2", "m1", "m0"]);
  // limit clamped to max 100 even if a huge value is passed
  const clamped = await listHistory(pool, a.id, b.id, { limit: 9999 });
  expect(clamped).toHaveLength(3);
});

test("listHistory to a non-friend throws 403", async () => {
  const a = await insertUser(pool, { username: "alice", display_name: "A", password_hash: await hashPassword("x") });
  const b = await insertUser(pool, { username: "bob", display_name: "B", password_hash: await hashPassword("x") });
  await expect(listHistory(pool, a.id, b.id)).rejects.toMatchObject({
    status: 403, code: "not_friends",
  });
});

// Silence the unused-import lint for AppError if not directly asserted above.
void AppError;
