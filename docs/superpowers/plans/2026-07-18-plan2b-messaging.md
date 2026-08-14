# PenguinChat Plan 2b - Messaging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add 1:1 real-time text messaging to PenguinChat - message send/receive with persistence, delivery and read receipts, typing indicators, and paged history - building entirely on the Plan 2a connection layer.

**Architecture:** A new `messaging` domain module (repo + service + socket handlers + REST route) sits on top of the Plan 2a `io`/`registry`. `message:send` persists the row, acks the sender, and fans `message:new` out to the recipient via `registry.notify`. Delivery receipts are client-driven: the recipient emits `message:delivered` on receipt, the server marks `delivered_at` and notifies the sender. Read receipts mark `read_at` by `created_at` cursor. No new transport, auth, infra, or database migration - reuses the Plan 1 `messages` table, `conversationId`, and the Plan 2a `SessionRegistry` seam.

**Tech Stack:** Node.js 20+, TypeScript (strict, ESM), Fastify 4, Socket.IO 4 (server + client), `pg`, Vitest, Docker (Postgres 16 + Redis 7 already in compose).

## Global Constraints

- Backend **always runs in Docker**; tests connect to the Dockerized Postgres **and** Redis. Docker is user-managed: NEVER restart the daemon or run `open -a Docker`. If Docker is down, report BLOCKED - do not start it.
- The global npm cache has permission issues; if any task runs `npm`, first `export npm_config_cache=/tmp/claude-501/-Users-winfredxu-penguinchat/deb5185c-85bd-4194-808f-98b389c6dd23/scratchpad/npm-cache`.
- TypeScript strict mode, ESM (`type: module`), `.js` import specifiers.
- Authorization is server-side: the acting identity is always `socket.data.userId` (the verified JWT sub from the Plan 2a gateway) or `request.userId` (the REST `requireAuth` plugin), NEVER a client-supplied `senderId`/`fromUserId`. `toUserId`/`peerId` ARE client-supplied but are validated against the friendship graph.
- Friends-only messaging: `message:send` and history both assert `areFriends(sender, peer)` - non-friends get an error ack (socket) or 403 (REST). Reuse `areFriends` from `src/modules/contacts/contacts.repo.ts`.
- `conversationId` is the deterministic UUIDv5 of the sorted user pair from `src/lib/ids.ts` - compute it server-side, never trust a client-supplied conversation id.
- Delivery receipt = "reached a device" (client-driven): recipient emits `message:delivered { messageId }`; server verifies the emitter IS the message's recipient, marks `delivered_at`, emits `message:delivered { messageId, delivered_at }` to the sender.
- `read_at` is marked by `created_at` cursor (NOT by uuid comparison - message ids are random UUIDs, not time-ordered): all messages in the conversation with `created_at <= (upToMessage's created_at)` where `recipient_id = reader`, never the reader's own sent messages.
- `clientMsgId` is returned in the `message:send` ack for client-side reconciliation; it is NOT persisted and NOT deduplicated in 2b.
- Existing 34 tests must stay green throughout; no REST behavior changes except the new history endpoint.

---

## File Structure

```
src/
  modules/
    messaging/
      messaging.repo.ts        # MessageRow type + insert/markDelivered/markRead/listByConversation/findById
      messaging.service.ts     # send (authz+persist), markDelivered, markRead, listHistory (authz+paging)
      messaging.handlers.ts    # registerMessagingHandlers(io, {pool, registry}) - socket events
      messaging.routes.ts      # GET /conversations/:peerId/messages
  realtime/
    gateway.ts                 # unchanged (handlers registered from server.ts/test fixture)
  server.ts                    # +registerMessagingHandlers(io, {pool, registry}) after createGateway
  app.ts                       # +register messagingRoutes with {pool}
test/
  helpers/
    realtime.ts                # +emitAck helper; +registerMessagingHandlers in makeRealtimeStack
  messaging.repo.test.ts
  messaging.service.test.ts
  messaging.handlers.test.ts
  messaging.routes.test.ts
```

**Boundaries:** `messaging.repo` owns SQL only. `messaging.service` owns authz (friends checks) + `conversationId` computation + paging logic. `messaging.handlers` owns the socket event surface (acks, fan-out via `registry`, per-socket listener registration). `messaging.routes` owns the REST history endpoint. Handlers and routes depend on the service; the service depends on the repo + `contacts.repo.areFriends` + `lib/ids.conversationId`. No module depends on Socket.IO internals except `messaging.handlers`.

---

## Task 1: messaging.repo (message-row CRUD)

**Files:**
- Create: `src/modules/messaging/messaging.repo.ts`
- Create: `test/messaging.repo.test.ts`

**Interfaces:**
- Consumes: `Pool` from `pg`; the Plan 1 `messages` table (columns: `id uuid`, `conversation uuid`, `sender_id uuid`, `recipient_id uuid`, `body text`, `created_at timestamptz`, `delivered_at timestamptz`, `read_at timestamptz`).
- Produces:
  - `MessageRow = { id: string; conversation: string; sender_id: string; recipient_id: string; body: string; created_at: string; delivered_at: string | null; read_at: string | null }`.
  - `insert(pool, input: { conversation: string; senderId: string; recipientId: string; body: string }): Promise<MessageRow>`.
  - `findById(pool, messageId: string): Promise<MessageRow | null>`.
  - `markDelivered(pool, messageId: string): Promise<MessageRow | null>` - sets `delivered_at = now()` only if currently null (idempotent); returns the updated row (or null if no such message).
  - `markRead(pool, conversation: string, readerId: string, upToMessageId: string): Promise<void>` - sets `read_at = now()` on rows where `conversation = $1 AND recipient_id = $2 AND created_at <= (SELECT created_at FROM messages WHERE id = $3) AND read_at IS NULL`.
  - `listByConversation(pool, conversation: string, opts: { before?: string; limit: number }): Promise<MessageRow[]>` - `WHERE conversation = $1 AND ($2::timestamptz IS NULL OR created_at < $2) ORDER BY created_at DESC LIMIT $3`.

- [ ] **Step 1: Write the failing test - `test/messaging.repo.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";
import { conversationId } from "../src/lib/ids.js";
import { insertUser } from "../src/modules/auth/auth.repo.js";
import { hashPassword } from "../src/modules/auth/password.js";
import {
  insert,
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/messaging.repo.test.ts`
Expected: FAIL - `src/modules/messaging/messaging.repo.ts` not found.

- [ ] **Step 3: Create `src/modules/messaging/messaging.repo.ts`**

```ts
import type { Pool } from "pg";

export interface MessageRow {
  id: string;
  conversation: string;
  sender_id: string;
  recipient_id: string;
  body: string;
  created_at: string;
  delivered_at: string | null;
  read_at: string | null;
}

export async function insert(
  pool: Pool,
  input: { conversation: string; senderId: string; recipientId: string; body: string }
): Promise<MessageRow> {
  const res = await pool.query<MessageRow>(
    `INSERT INTO messages (conversation, sender_id, recipient_id, body)
     VALUES ($1, $2, $3, $4) RETURNING *`,
    [input.conversation, input.senderId, input.recipientId, input.body]
  );
  return res.rows[0];
}

export async function findById(pool: Pool, messageId: string): Promise<MessageRow | null> {
  const res = await pool.query<MessageRow>("SELECT * FROM messages WHERE id = $1", [messageId]);
  return res.rows[0] ?? null;
}

/** Sets delivered_at = now() only if currently null (idempotent). Returns the row or null. */
export async function markDelivered(pool: Pool, messageId: string): Promise<MessageRow | null> {
  const res = await pool.query<MessageRow>(
    `UPDATE messages SET delivered_at = now()
     WHERE id = $1 AND delivered_at IS NULL RETURNING *`,
    [messageId]
  );
  if (res.rowCount) return res.rows[0];
  // Either the message doesn't exist or it was already delivered - return current state.
  return findById(pool, messageId);
}

/** Marks read_at on the reader's received messages up to (and including) upToMessageId, by created_at. */
export async function markRead(
  pool: Pool,
  conversation: string,
  readerId: string,
  upToMessageId: string
): Promise<void> {
  await pool.query(
    `UPDATE messages SET read_at = now()
     WHERE conversation = $1
       AND recipient_id = $2
       AND read_at IS NULL
       AND created_at <= (SELECT created_at FROM messages WHERE id = $3)`,
    [conversation, readerId, upToMessageId]
  );
}

export async function listByConversation(
  pool: Pool,
  conversation: string,
  opts: { before?: string; limit: number }
): Promise<MessageRow[]> {
  const res = await pool.query<MessageRow>(
    `SELECT * FROM messages
     WHERE conversation = $1 AND ($2::timestamptz IS NULL OR created_at < $2)
     ORDER BY created_at DESC
     LIMIT $3`,
    [conversation, opts.before ?? null, opts.limit]
  );
  return res.rows;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/messaging.repo.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(2b): messaging repo - insert/findById/markDelivered/markRead/list"
```

---

## Task 2: messaging.service (send + authz + history paging)

**Files:**
- Create: `src/modules/messaging/messaging.service.ts`
- Create: `test/messaging.service.test.ts`

**Interfaces:**
- Consumes: `messaging.repo` (`insert`, `markDelivered`, `markRead`, `listByConversation`, `findById`, `MessageRow`) from Task 1; `areFriends` from `src/modules/contacts/contacts.repo.ts`; `conversationId` from `src/lib/ids.ts`; `AppError` from `src/lib/errors.ts`.
- Produces:
  - `PublicMessage = MessageRow` (the full row is returned to clients; nothing sensitive to strip).
  - `send(pool, senderId, input: { toUserId: string; body: string }): Promise<MessageRow>` - asserts `areFriends(sender, toUser)` (else `AppError(403, "not_friends", ...)`); computes `conversationId(senderId, toUserId)`; calls `insert`.
  - `markDelivered(pool, messageId): Promise<MessageRow | null>` - thin wrapper over repo.
  - `markRead(pool, readerId, peerId, upToMessageId): Promise<{ conversation: string }>` - asserts `areFriends(reader, peer)` (else 403); computes `conversationId`; calls repo `markRead`; returns `{ conversation }` for the fan-out payload.
  - `listHistory(pool, userId, peerId, opts: { before?: string; limit?: number }): Promise<MessageRow[]>` - asserts `areFriends` (else 403); clamps `limit` to [1, 100] default 50; computes `conversationId`; calls `listByConversation`.

- [ ] **Step 1: Write the failing test - `test/messaging.service.test.ts`**

```ts
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/messaging.service.test.ts`
Expected: FAIL - `messaging.service` not found.

- [ ] **Step 3: Create `src/modules/messaging/messaging.service.ts`**

```ts
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import { conversationId } from "../../lib/ids.js";
import { areFriends } from "../contacts/contacts.repo.js";
import {
  insert,
  listByConversation,
  markDelivered as repoMarkDelivered,
  markRead as repoMarkRead,
  type MessageRow,
} from "./messaging.repo.js";

export type { MessageRow } from "./messaging.repo.js";

export async function send(
  pool: Pool,
  senderId: string,
  input: { toUserId: string; body: string }
): Promise<MessageRow> {
  if (!(await areFriends(pool, senderId, input.toUserId))) {
    throw new AppError(403, "not_friends", "You can only message friends");
  }
  const conversation = conversationId(senderId, input.toUserId);
  return insert(pool, {
    conversation,
    senderId,
    recipientId: input.toUserId,
    body: input.body,
  });
}

export async function markDelivered(pool: Pool, messageId: string): Promise<MessageRow | null> {
  return repoMarkDelivered(pool, messageId);
}

export async function markRead(
  pool: Pool,
  readerId: string,
  peerId: string,
  upToMessageId: string
): Promise<{ conversation: string }> {
  if (!(await areFriends(pool, readerId, peerId))) {
    throw new AppError(403, "not_friends", "You can only read your own conversations");
  }
  const conversation = conversationId(readerId, peerId);
  await repoMarkRead(pool, conversation, readerId, upToMessageId);
  return { conversation };
}

export async function listHistory(
  pool: Pool,
  userId: string,
  peerId: string,
  opts: { before?: string; limit?: number } = {}
): Promise<MessageRow[]> {
  if (!(await areFriends(pool, userId, peerId))) {
    throw new AppError(403, "not_friends", "You can only read your own conversations");
  }
  const conversation = conversationId(userId, peerId);
  const limit = Math.max(1, Math.min(100, opts.limit ?? 50));
  return listByConversation(pool, conversation, { before: opts.before, limit });
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/messaging.service.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(2b): messaging service - send/markRead/listHistory with friends authz"
```

---

## Task 3: messaging.handlers (socket events) + wire into gateway setup

**Files:**
- Create: `src/modules/messaging/messaging.handlers.ts`
- Modify: `src/server.ts` (call `registerMessagingHandlers` after `createGateway`)
- Modify: `test/helpers/realtime.ts` (add `emitAck` helper; call `registerMessagingHandlers` in `makeRealtimeStack`)
- Create: `test/messaging.handlers.test.ts`

**Interfaces:**
- Consumes: `Pool`; `SessionRegistry` (`notify(userId, event, payload)`); `messaging.service` (`send`, `markDelivered`, `markRead`); `messaging.repo` (`findById`); `Server`/`Socket` from `socket.io`; `socket.data.userId` set by the Plan 2a gateway.
- Produces: `registerMessagingHandlers(io: Server, deps: { pool: Pool; registry: SessionRegistry }): void`:
  - On `"connection"`, attaches per-socket listeners (acting identity = `socket.data.userId`):
    - `message:send` `(payload: { toUserId, body, clientMsgId }, ack)` - calls `send`; on success fans `registry.notify(toUserId, "message:new", { message })` and acks `{ id, created_at, clientMsgId }`; on `AppError` acks `{ error: err.code }`.
    - `message:delivered` `(payload: { messageId })` - looks up the message via `findById`; if `message.recipient_id === socket.data.userId`, calls `markDelivered` and fans `registry.notify(message.sender_id, "message:delivered", { messageId, delivered_at })`. (If the emitter is not the recipient, ignore - do not mark.)
    - `message:read` `(payload: { peerId, upToMessageId })` - calls `markRead(socketUser, peerId, upToMessageId)`; on success fans `registry.notify(peerId, "message:read", { conversationId: result.conversation, upToMessageId })`.
    - `typing:start` / `typing:stop` `(payload: { toUserId })` - fans `registry.notify(toUserId, "typing", { fromUserId: socketUser, isTyping: true|false })`.
  - All handlers route async work through a `safe()` `.catch` wrapper (same pattern as `presence.handlers.ts`) EXCEPT `message:send`, which uses try/catch to call `ack` in both success and error.

- [ ] **Step 1: Add the `emitAck` helper to `test/helpers/realtime.ts`**

Append to `test/helpers/realtime.ts`:

```ts
/** Emit a socket event and resolve its ack. */
export function emitAck(
  sock: ClientSocket,
  event: string,
  payload: unknown
): Promise<unknown> {
  return new Promise((resolve) => {
    sock.emit(event, payload, (ack: unknown) => resolve(ack));
  });
}
```

- [ ] **Step 2: Wire `registerMessagingHandlers` into `test/helpers/realtime.ts` `makeRealtimeStack`**

In `makeRealtimeStack`, after `const io = createGateway(...)` and before `registry.attach(io)`, add:

```ts
  const { registerMessagingHandlers } = await import("../../src/modules/messaging/messaging.handlers.js");
  registerMessagingHandlers(io, { pool, registry });
```

- [ ] **Step 3: Write the failing test - `test/messaging.handlers.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  socketClient,
  emitAck,
  registerUser,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("message:send acks the sender and delivers message:new to the recipient", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const received = new Promise((r) => bobSock.on("message:new", r));
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id,
    body: "hi bob",
    clientMsgId: "c1",
  })) as { id: string; created_at: string; clientMsgId: string };
  expect(ack.id).toBeTruthy();
  expect(ack.clientMsgId).toBe("c1");
  const incoming = (await received) as { message: { body: string; sender_id: string } };
  expect(incoming.message.body).toBe("hi bob");
  expect(incoming.message.sender_id).toBe(alice.id);
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:delivered marks delivered_at and notifies the sender", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice2", "bob2");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id, body: "hi", clientMsgId: "c2",
  })) as { id: string };
  // Bob receives then confirms delivery.
  await new Promise((r) => bobSock.on("message:new", r));
  const deliveredSeen = new Promise((r) => aliceSock.on("message:delivered", r));
  await emitAck(bobSock, "message:delivered", { messageId: ack.id });
  const deliv = (await deliveredSeen) as { messageId: string; delivered_at: string };
  expect(deliv.messageId).toBe(ack.id);
  expect(deliv.delivered_at).toBeTruthy();
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:read fans out message:read to the peer with the conversation id", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice3", "bob3");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const sendAck = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id, body: "read me", clientMsgId: "c3",
  })) as { id: string };
  await new Promise((r) => bobSock.on("message:new", r));
  const readSeen = new Promise((r) => aliceSock.on("message:read", r));
  await emitAck(bobSock, "message:read", { peerId: alice.id, upToMessageId: sendAck.id });
  const read = (await readSeen) as { conversationId: string; upToMessageId: string };
  expect(read.upToMessageId).toBe(sendAck.id);
  expect(read.conversationId).toBeTruthy();
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("typing:start fans out a typing event to the peer", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice4", "bob4");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const typingSeen = new Promise((r) => bobSock.on("typing", r));
  await emitAck(aliceSock, "typing:start", { toUserId: bob.id });
  const typing = (await typingSeen) as { fromUserId: string; isTyping: boolean };
  expect(typing.fromUserId).toBe(alice.id);
  expect(typing.isTyping).toBe(true);
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:send to a non-friend acks an error and does not deliver", async () => {
  const alice = await registerUser(stack.app, "alice5");
  const carol = await registerUser(stack.app, "carol5"); // not friends
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const carolSock = await socketClient(stack.port, carol.accessToken);
  const carolGotMessage = new Promise((resolve, reject) => {
    carolSock.on("message:new", () => reject(new Error("should not receive")));
    setTimeout(() => resolve(undefined), 200);
  });
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: carol.id, body: "hi", clientMsgId: "c4",
  })) as { error: string };
  expect(ack.error).toBe("not_friends");
  await carolGotMessage; // resolves without carol receiving anything
  aliceSock.disconnect();
  carolSock.disconnect();
});
```

- [ ] **Step 4: Run it to verify it fails**

Run: `npm test -- test/messaging.handlers.test.ts`
Expected: FAIL - `messaging.handlers` not found.

- [ ] **Step 5: Create `src/modules/messaging/messaging.handlers.ts`**

```ts
import type { Server, Socket } from "socket.io";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import { findById } from "./messaging.repo.js";
import { markDelivered, markRead, send } from "./messaging.service.js";

export interface MessagingHandlerDeps {
  pool: Pool;
  registry: SessionRegistry;
}

export function registerMessagingHandlers(io: Server, deps: MessagingHandlerDeps): void {
  const { pool, registry } = deps;

  // Socket.IO does not await async listeners; route fire-and-forget handlers
  // through safe() so failures are logged rather than becoming unhandled rejections.
  const safe = (fn: () => Promise<void>): void => {
    fn().catch((err) => {
      // eslint-disable-next-line no-console
      console.error("messaging handler error:", err);
    });
  };

  io.on("connection", (socket: Socket) => {
    const userId = socket.data.userId as string;

    socket.on("message:send", (payload: { toUserId: string; body: string; clientMsgId: string }, ack: (r: unknown) => void) => {
      (async () => {
        try {
          const message = await send(pool, userId, { toUserId: payload.toUserId, body: payload.body });
          await registry.notify(payload.toUserId, "message:new", { message });
          ack({ id: message.id, created_at: message.created_at, clientMsgId: payload.clientMsgId });
        } catch (err) {
          ack({ error: err instanceof AppError ? err.code : "internal" });
        }
      })();
    });

    socket.on("message:delivered", (payload: { messageId: string }) => {
      safe(async () => {
        const message = await findById(pool, payload.messageId);
        if (!message) return;
        // Only the message's recipient can confirm delivery.
        if (message.recipient_id !== userId) return;
        const updated = await markDelivered(pool, payload.messageId);
        if (!updated || !updated.delivered_at) return;
        await registry.notify(message.sender_id, "message:delivered", {
          messageId: payload.messageId,
          delivered_at: updated.delivered_at,
        });
      });
    });

    socket.on("message:read", (payload: { peerId: string; upToMessageId: string }) => {
      safe(async () => {
        const result = await markRead(pool, userId, payload.peerId, payload.upToMessageId);
        await registry.notify(payload.peerId, "message:read", {
          conversationId: result.conversation,
          upToMessageId: payload.upToMessageId,
        });
      });
    });

    const onTyping = (isTyping: boolean) => (payload: { toUserId: string }) => {
      safe(async () => {
        await registry.notify(payload.toUserId, "typing", { fromUserId: userId, isTyping });
      });
    };
    socket.on("typing:start", onTyping(true));
    socket.on("typing:stop", onTyping(false));
  });
}
```

- [ ] **Step 6: Wire `registerMessagingHandlers` into `src/server.ts`**

In `src/server.ts`, after `const io = createGateway(...)` and before `registry.attach(io)`, add (and the import at top):

```ts
import { registerMessagingHandlers } from "./modules/messaging/messaging.handlers.js";
// ...
  registerMessagingHandlers(io, { pool, registry });
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `npm test -- test/messaging.handlers.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(2b): messaging socket handlers - send/delivered/read/typing"
```

---

## Task 4: messaging.routes (history endpoint) + wire into app.ts

**Files:**
- Create: `src/modules/messaging/messaging.routes.ts`
- Modify: `src/app.ts` (register `messagingRoutes` with `{ pool }`)
- Create: `test/messaging.routes.test.ts`

**Interfaces:**
- Consumes: `messaging.service.listHistory`; `requireAuth` plugin (`request.userId`); Fastify.
- Produces: `messagingRoutes` Fastify plugin providing `GET /conversations/:peerId/messages?before=&limit=`. Returns `{ messages: [...] }`. `limit` parsed as integer, clamped server-side by `listHistory`. `before` is the exclusive `created_at` cursor (string).

- [ ] **Step 1: Write the failing test - `test/messaging.routes.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makePool, makeApp } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";
import { makeFriends } from "./helpers/friends.js";
import { io as ioc } from "socket.io-client";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;

beforeAll(async () => {
  await runMigrations(pool);
});
beforeEach(async () => {
  await resetDb(pool);
  app = await makeApp(pool);
});
afterAll(async () => {
  await app.close();
  await pool.end();
});

async function sendViaSocket(port: number, token: string, toUserId: string, body: string) {
  const sock = ioc(`http://localhost:${port}`, { auth: { token } });
  await new Promise((r) => sock.on("connect", r));
  const msg = await new Promise<any>((resolve) =>
    sock.emit("message:send", { toUserId, body, clientMsgId: body }, resolve)
  );
  sock.disconnect();
  return msg;
}

test("GET /conversations/:peerId/messages returns messages newest-first", async () => {
  const { a: alice, b: bob } = await makeFriends(app, "alice", "bob");
  // Need the realtime stack for socket send; reuse makeApp's port by listening.
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  for (let i = 0; i < 3; i++) {
    await sendViaSocket(port, alice.accessToken, bob.id, `m${i}`);
    await new Promise((r) => setTimeout(r, 10));
  }
  const res = await app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=50`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().messages.map((m: any) => m.body)).toEqual(["m2", "m1", "m0"]);
});

test("GET /conversations/:peerId/messages paginates with the before cursor", async () => {
  const { a: alice, b: bob } = await makeFriends(app, "alice2", "bob2");
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const ids: string[] = [];
  for (let i = 0; i < 3; i++) {
    const m = await sendViaSocket(port, alice.accessToken, bob.id, `m${i}`);
    ids.push(m.id);
    await new Promise((r) => setTimeout(r, 10));
  }
  const page1 = await app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  const p1 = page1.json().messages;
  expect(p1).toHaveLength(2);
  const page2 = await app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2&before=${encodeURIComponent(p1[1].created_at)}`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(page2.json().messages.map((m: any) => m.body)).toEqual(["m0"]);
});

test("GET /conversations/:peerId/messages to a non-friend returns 403", async () => {
  const alice = await (await import("./helpers/realtime.js")).registerUser(app, "alice3");
  const carol = await (await import("./helpers/realtime.js")).registerUser(app, "carol3");
  await app.listen({ port: 0, host: "127.0.0.1" });
  const res = await app.inject({
    method: "GET",
    url: `/conversations/${carol.id}/messages`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(403);
  expect(res.json().error).toBe("not_friends");
});

test("GET /conversations/:peerId/messages without auth returns 401", async () => {
  await app.listen({ port: 0, host: "127.0.0.1" });
  const res = await app.inject({ method: "GET", url: `/conversations/00000000-0000-0000-0000-000000000000/messages` });
  expect(res.statusCode).toBe(401);
});
```

> **Note:** `makeApp` (from `test/helpers/app.ts`) does NOT register messaging routes until Task 4's `app.ts` change lands. The test wires both REST (`app.inject`) and a socket (via `app.listen` + `socket.io-client`) - but `makeApp`'s app has NO `io` attached, so socket `message:send` won't work against it. **Resolution:** this test must use `makeRealtimeStack` (which wires the full socket stack) instead of `makeApp`. Rewrite the test's setup to use `makeRealtimeStack`:

Replace the test file's setup section (top through `afterAll`) with:

```ts
import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  registerUser,
  emitAck,
  socketClient,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";
import { io as ioc } from "socket.io-client";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

async function sendViaSocket(token: string, toUserId: string, body: string) {
  const sock = await socketClient(stack.port, token);
  const msg = (await emitAck(sock, "message:send", { toUserId, body, clientMsgId: body })) as { id: string };
  sock.disconnect();
  return msg;
}
```

And each test starts with `stack = await makeRealtimeStack();` and uses `stack.app.inject(...)` + `sendViaSocket(alice.accessToken, bob.id, ...)`. The `beforeEach`/`makeApp` approach above is dropped. (Apply this `makeRealtimeStack`-based version; discard the `makeApp` version.)

Final test bodies (using `stack`):

```ts
test("GET /conversations/:peerId/messages returns messages newest-first", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  for (let i = 0; i < 3; i++) {
    await sendViaSocket(alice.accessToken, bob.id, `m${i}`);
    await new Promise((r) => setTimeout(r, 10));
  }
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=50`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().messages.map((m: any) => m.body)).toEqual(["m2", "m1", "m0"]);
});

test("paginates with the before cursor", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice2", "bob2");
  for (let i = 0; i < 3; i++) {
    await sendViaSocket(alice.accessToken, bob.id, `m${i}`);
    await new Promise((r) => setTimeout(r, 10));
  }
  const page1 = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  const p1 = page1.json().messages;
  const page2 = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2&before=${encodeURIComponent(p1[1].created_at)}`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(page2.json().messages.map((m: any) => m.body)).toEqual(["m0"]);
});

test("to a non-friend returns 403", async () => {
  stack = await makeRealtimeStack();
  const alice = await registerUser(stack.app, "alice3");
  const carol = await registerUser(stack.app, "carol3");
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/${carol.id}/messages`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(403);
  expect(res.json().error).toBe("not_friends");
});

test("without auth returns 401", async () => {
  stack = await makeRealtimeStack();
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/00000000-0000-0000-0000-000000000000/messages`,
  });
  expect(res.statusCode).toBe(401);
});
```

> Discard the `ioc` import (unused in the final version) - the rewritten `sendViaSocket` uses `socketClient`/`emitAck` from the realtime helper.

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/messaging.routes.test.ts`
Expected: FAIL - `messagingRoutes` not found / `/conversations/.../messages` 404s.

- [ ] **Step 3: Create `src/modules/messaging/messaging.routes.ts`**

```ts
import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import { listHistory } from "./messaging.service.js";

interface Opts {
  pool: Pool;
}

export async function messagingRoutes(app: FastifyInstance, opts: Opts) {
  app.get("/conversations/:peerId/messages", { preHandler: app.requireAuth }, async (req) => {
    const { peerId } = req.params as { peerId: string };
    const query = req.query as { before?: string; limit?: string };
    const limit = query.limit !== undefined ? Number(query.limit) : undefined;
    if (query.limit !== undefined && (!Number.isFinite(limit) || limit <= 0)) {
      throw new AppError(400, "invalid_payload", "limit must be a positive number");
    }
    const messages = await listHistory(opts.pool, req.userId!, peerId, {
      before: query.before,
      limit,
    });
    return { messages };
  });
}
```

- [ ] **Step 4: Modify `src/app.ts` - register messaging routes**

Add the import and registration. After the `contactsRoutes` registration line:

```ts
import { messagingRoutes } from "./modules/messaging/messaging.routes.js";
// ...
  app.register(messagingRoutes, { pool: deps.pool });
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- test/messaging.routes.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Run the full suite**

Run: `npm test`
Expected: PASS - all prior tests + the new messaging tests.

- [ ] **Step 7: Verify strict build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat(2b): GET /conversations/:peerId/messages history endpoint"
```

---

## Task 5: Container boot verification + full suite green

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Rebuild the container**

```bash
docker compose up -d --build
```

If Docker is down, report BLOCKED (do not start it). If the build fails to pull `node:20-slim` (registry unreachable), ask the user to run `docker pull node:20-slim` in their terminal, then retry.

- [ ] **Step 2: Confirm the container boots with the messaging routes**

```bash
docker compose logs api --tail 20 | grep -i "listening"
```
Expected: `PenguinChat API + realtime listening on :3000`.

- [ ] **Step 3: Confirm the history endpoint responds (self-migrated, auth-enforced)**

```bash
# No auth -> 401 (proves the route exists and authz is enforced)
curl -s -o /dev/null -w "no-auth=%{http_code}\n" localhost:3000/conversations/00000000-0000-0000-0000-000000000000/messages
```
Expected: `no-auth=401`.

- [ ] **Step 4: Run the full suite one more time**

Run: `npm test`
Expected: all tests PASS.

- [ ] **Step 5: Leave infra in a clean running state**

```bash
docker compose up -d postgres redis
```

- [ ] **Step 6: Commit (only if docs changed; otherwise skip)**

If no files changed, skip. Otherwise:

```bash
git add -A
git commit -m "chore(2b): verify containerized messaging boot"
```

---

## Self-Review Notes (author - completed)

- **Spec coverage:** `message:send` (persist + ack + `message:new` fan-out) ✔ (Task 3); `message:new` server->client ✔ (Task 3); `message:delivered` client-driven delivery hook (recipient confirms -> mark `delivered_at` -> notify sender) ✔ (Task 3); `message:read` (mark `read_at` + `message:read` fan-out) ✔ (Tasks 1+3); `typing:start`/`stop` -> `typing` ✔ (Task 3); `GET /conversations/:peerId/messages` paged history ✔ (Task 4); friends-only authz on send + read + history ✔ (Task 2); `(conversation, created_at)` paging ✔ (Task 1); `conversationId` reuse ✔ (Task 2); `messages` table reuse, no migration ✔.
- **Spec bug fixed during planning:** the spec's `markRead` used `id <= upToMessageId` (uuid comparison, meaningless). Task 1 uses `created_at <= (SELECT created_at FROM messages WHERE id = $3)` - the correct "up to here" semantic. Called out in Global Constraints.
- **Placeholder scan:** none - every step has complete code or an exact command. The Task 4 test had a `makeApp`-vs-`makeRealtimeStack` issue caught during planning; the brief explicitly directs the implementer to the `makeRealtimeStack` version and discards the `makeApp` draft.
- **Type consistency:** `MessageRow` is the single message shape, re-exported from `messaging.service` and used by handlers. `registerMessagingHandlers(io, { pool, registry })` matches the wiring in `server.ts` and `makeRealtimeStack`. `markRead` service returns `{ conversation: string }`; the handler uses `result.conversation` as the `conversationId` in the fan-out payload - names align. `listHistory` opts `{ before?: string; limit?: number }` matches the route's parsing. `emitAck` helper added to `test/helpers/realtime.ts` and used by both the handlers test and the routes test's `sendViaSocket`.
- **Plan-2a regression risk:** none - `app.ts` only ADDS `messagingRoutes` registration; no existing route or handler changes. `server.ts` only ADDS the `registerMessagingHandlers` call. The gateway is unchanged. Existing 34 tests untouched.
- **Authz trace:** `message:send` -> `send` -> `areFriends` check. `message:read` -> `markRead` -> `areFriends` check. `message:delivered` -> `findById` + `message.recipient_id === socket.data.userId` check (only the recipient can mark delivered). History -> `listHistory` -> `areFriends`. Acting identity always `socket.data.userId` / `req.userId`, never client-supplied.
