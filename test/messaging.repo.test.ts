import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";
import { conversationId } from "../src/lib/ids.js";
import { insertUser } from "../src/modules/auth/auth.repo.js";
import { hashPassword } from "../src/modules/auth/password.js";
import {
  insert,
  insertIdempotent,
  findById,
  markDelivered,
  markRead,
  listByConversation,
} from "../src/modules/messaging/messaging.repo.js";

const pool = makePool();
const CONV = conversationId(
  "11111111-1111-1111-1111-111111111111",
  "22222222-2222-2222-2222-222222222222"
);

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await pool.end(); });

async function seedUsers() {
  const a = await insertUser(pool, { username: "alice", display_name: "A", password_hash: await hashPassword("x") });
  const b = await insertUser(pool, { username: "bob", display_name: "B", password_hash: await hashPassword("x") });
  return { a, b };
}

test("insert + findById round-trips a message row", async () => {
  const { a, b } = await seedUsers();
  const msg = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: "hi" });
  expect(msg.id).toBeTruthy();
  expect(msg.body).toBe("hi");
  expect(msg.delivered_at).toBeNull();
  expect(msg.read_at).toBeNull();
  const found = await findById(pool, msg.id);
  expect(found?.body).toBe("hi");
});

test("insertIdempotent reuses the sender's message for the same client id", async () => {
  const { a, b } = await seedUsers();
  const input = {
    conversation: CONV,
    senderId: a.id,
    recipientId: b.id,
    body: "retry once",
    clientMsgId: "client-retry-1",
  };
  const first = await insertIdempotent(pool, input);
  const retry = await insertIdempotent(pool, input);
  expect(first.inserted).toBe(true);
  expect(retry.inserted).toBe(false);
  expect(retry.message.id).toBe(first.message.id);
  expect(retry.message.client_msg_id).toBe(input.clientMsgId);
});

test("markDelivered sets delivered_at and is idempotent", async () => {
  const { a, b } = await seedUsers();
  const msg = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: "hi" });
  const first = await markDelivered(pool, msg.id);
  expect(first?.delivered_at).not.toBeNull();
  const second = await markDelivered(pool, msg.id);
  // Idempotent: second call does not change the timestamp.
  expect(second?.delivered_at).toBe(first?.delivered_at);
});

test("markRead sets read_at on recipient's messages up to the cursor, not on sender's own", async () => {
  const { a, b } = await seedUsers();
  // Three messages a->b, then one b->a.
  const m1 = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: "1" });
  // small delay so created_at ordering is stable
  await new Promise((r) => setTimeout(r, 10));
  const m2 = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: "2" });
  await new Promise((r) => setTimeout(r, 10));
  const m3 = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: "3" });
  await new Promise((r) => setTimeout(r, 10));
  const m4 = await insert(pool, { conversation: CONV, senderId: b.id, recipientId: a.id, body: "back" });

  // Bob (recipient of m1..m3) reads up to m2.
  await markRead(pool, CONV, b.id, m2.id);
  const after = await listByConversation(pool, CONV, { limit: 50 });
  const byId = new Map(after.map((m) => [m.id, m]));
  expect(byId.get(m1.id)?.read_at).not.toBeNull();
  expect(byId.get(m2.id)?.read_at).not.toBeNull();
  expect(byId.get(m3.id)?.read_at).toBeNull(); // after the cursor
  expect(byId.get(m4.id)?.read_at).toBeNull(); // b's own send, never marked
});

test("listByConversation pages newest-first with an exclusive before cursor", async () => {
  const { a, b } = await seedUsers();
  const ids: string[] = [];
  for (let i = 0; i < 3; i++) {
    const m = await insert(pool, { conversation: CONV, senderId: a.id, recipientId: b.id, body: `m${i}` });
    ids.push(m.id);
    await new Promise((r) => setTimeout(r, 10));
  }
  const page1 = await listByConversation(pool, CONV, { limit: 2 });
  expect(page1).toHaveLength(2);
  expect(page1[0].body).toBe("m2"); // newest first
  expect(page1[1].body).toBe("m1");
  // Cursor at page1's oldest (m1); next page should return m0 only.
  const page2 = await listByConversation(pool, CONV, { before: page1[1].created_at, limit: 2 });
  expect(page2).toHaveLength(1);
  expect(page2[0].body).toBe("m0");
});
