# PenguinChat — Plan 2b Design: Messaging

- **Status:** design approved
- **Date:** 2026-07-18
- **Parent spec:** `docs/system_design.md` (§3 architecture, §4 domain boundaries, §5 data model, §6 real-time surface, §8 security)
- **Follows:** Plan 1 (auth + contacts REST) and Plan 2a (real-time connection layer + presence), both merged to `main`
- **Precedes:** Plan 3 (Electron/React client)

---

## 1. Goal

Add the messaging subsystem to PenguinChat: 1:1 real-time text messages that persist as history, with delivery and read receipts and typing indicators. This completes the v1 real-time surface from `system_design.md` §6. It builds entirely on the Plan 2a connection layer (Socket.IO gateway with JWT handshake auth, `RedisSessionRegistry` fan-out via `io.to(userId)`, presence) — no new transport or auth concerns.

## 2. Decisions (locked with the user)

1. **Delivery receipt = "reached a device" (Option A, client-driven).** `delivered_at` is set when the recipient's client, upon receiving `message:new`, emits `message:delivered { messageId }` back to the server. The server then marks `delivered_at` on the row and emits `message:delivered { messageId, delivered_at }` to the sender. This is the honest semantic: if the recipient is offline, no delivered tick is set until they next connect and receive the queued message. (§6's `message:delivered` server→client event is preserved exactly; we add one client→server `message:delivered` event not in the §6 table.)
2. **Read receipts:** `message:read` (client→server) carries `{ conversationId, upToMessageId }`. The server marks `read_at` on all messages in that conversation up to `upToMessageId` where the reader is the recipient, then emits `message:read { conversationId, upToMessageId }` to the conversation peer. `read_at` is never set on the reader's own sent messages.

## 3. Architecture

```
   sender socket                    server                          recipient socket
   ─────────────                    ──────                          ───────────────
   message:send ──────────────►  messaging.handlers
     {toUserId, body, clientMsgId}   │
                                     ├─ authz: areFriends(sender, toUserId)?
                                     ├─ conversationId(sender, toUserId)  (src/lib/ids.ts)
                                     ├─ repo.insert(message)  → row with id, created_at
                                     ├─ ack sender: { id, created_at }     ◄── (sender reconciles optimistic bubble via clientMsgId)
                                     └─ registry.notify(toUserId, "message:new", { message })
                                                                        ──────────────►  receives message:new
                                                                                          │
                                                                                          └─ emits message:delivered { messageId }
                                                                        ◄──────────────
                                     messaging.handlers.message:delivered
                                       ├─ repo.markDelivered(messageId)
                                       └─ registry.notify(sender, "message:delivered", { messageId, delivered_at })
   receives message:delivered ◄──────────────────────────────────────────────
```

### Components (new)

- **`src/modules/messaging/messaging.repo.ts`** — message-row CRUD against the Plan 1 `messages` table:
  - `insert({ conversation, senderId, recipientId, body })` → `MessageRow`
  - `markDelivered(messageId)` → sets `delivered_at = now()` (idempotent — no-op if already set)
  - `markRead(conversation, upToMessageId, readerId)` → sets `read_at = now()` on rows where `conversation = $1 AND id <= upToMessageId AND recipient_id = readerId` (only messages the reader received; never their own sends)
  - `listByConversation(conversation, { before, limit })` → paged rows, newest-first walking backward on the `(conversation, created_at)` index; `before` is a cursor (the `created_at` of the last loaded message, exclusive)
  - `findById(messageId)` → for the delivered hook (to look up the sender)
- **`src/modules/messaging/messaging.service.ts`** — orchestration + authz:
  - `send(pool, senderId, { toUserId, body, clientMsgId })` — assert `areFriends(sender, toUser)` (else 403-ish `not_friends`); compute `conversationId`; persist; return the row. (`clientMsgId` is NOT persisted in 2b — it's an idempotency/reconciliation hint returned to the client only; see §7.)
  - `markDelivered(pool, messageId)` — repo call.
  - `markRead(pool, readerId, conversationId, upToMessageId)` — assert the reader is a participant in the conversation (derive the pair from `conversationId` is not possible — it's a UUIDv5 hash — so instead assert `areFriends(reader, peer)` where peer is known from the request context; see §5).
  - `listHistory(pool, userId, peerId, { before, limit })` — assert `areFriends(user, peer)`; compute `conversationId`; page.
- **`src/modules/messaging/messaging.handlers.ts`** — socket event wiring (registered on `io` like the presence handlers). Each socket gets listeners for `message:send`, `message:delivered`, `message:read`, `typing:start`, `typing:stop`. All use `socket.data.userId` (from the gateway's handshake auth) as the acting identity; client-supplied `fromUserId`/`senderId` is never trusted.
- **`src/modules/messaging/messaging.routes.ts`** — `GET /conversations/:peerId/messages?before=&limit=50` behind `requireAuth`.

### Composing with Plan 2a

The messaging handlers attach to the same `io` the gateway creates. They are registered by extending the gateway's `connection` listener (or a sibling `registerMessagingHandlers(io, deps)` call), adding per-socket listeners. They need: the `pool`, the `registry` (for fan-out), and — for `message:delivered` — the ability to look up the original message's sender (via `repo.findById`). The gateway's handshake auth already set `socket.data.userId`, so messaging never re-authenticates.

### Wiring

`buildApp`/`server.ts` gain the messaging module the same way contacts/presence did: `messagingRoutes` registered in `buildApp` with `{ pool, registry }`; `registerMessagingHandlers(io, { pool, registry })` called from the gateway setup (alongside `registerPresenceHandlers`). No new config, no new infra.

## 4. Data model (unchanged from Plan 1)

The `messages` table already exists (`001_init.sql`):
```sql
id uuid PK, conversation uuid, sender_id uuid, recipient_id uuid,
body text, created_at timestamptz, delivered_at timestamptz, read_at timestamptz
INDEX (conversation, created_at)
```
**No migration is needed for 2b.** `conversation` is the deterministic UUIDv5 of the sorted user pair (`src/lib/ids.ts` `conversationId`). `delivered_at` and `read_at` start `null`.

## 5. API & real-time surface (2b portion)

### REST
```
GET /conversations/:peerId/messages?before=<iso8601>&limit=50 → { messages: [...] }
```
- `peerId` is the other user's id. `before` is an exclusive cursor (the `created_at` of the oldest already-loaded message); omitted on the first page. `limit` defaults to 50, capped at 100.
- Returns messages newest-first. Authorization: `areFriends(userId, peerId)` else 403.

### Socket.IO events (2b portion of §6)

**Client → server**

| Event | Payload | Notes |
|-------|---------|-------|
| `message:send` | `{ toUserId, body, clientMsgId }` | ack → `{ id, created_at }`; persisted + delivered to recipient |
| `message:delivered` | `{ messageId }` | recipient confirms receipt → server marks `delivered_at` + emits `message:delivered` to sender |
| `message:read` | `{ conversationId, upToMessageId }` | marks read up to here |
| `typing:start` / `typing:stop` | `{ toUserId }` | fan-out only; no persistence |

**Server → client**

| Event | Payload | Meaning |
|-------|---------|---------|
| `message:new` | `{ message }` | incoming chat (full row) |
| `message:delivered` | `{ messageId, delivered_at }` | your sent message reached the recipient's device |
| `message:read` | `{ conversationId, upToMessageId }` | recipient read up to here |
| `typing` | `{ fromUserId, isTyping }` | typing indicator |

## 6. Authorization & security

- **Friends-only messaging:** `message:send` and history both assert `areFriends(sender, peer)` — you can only message people on your contact list. Non-friends → 403 (REST) / error ack (socket).
- **Acting identity is always `socket.data.userId`** (the verified JWT sub) — never read `senderId`/`fromUserId` from the client payload. `toUserId`/`peerId` ARE client-supplied (that's the whole point — who you're messaging), but are validated against the friendship graph.
- **Read-receipt participant check:** `message:read` carries a `conversationId`. The server must verify the reader is actually a participant. Since `conversationId` is a one-way hash, the handler receives `{ conversationId, upToMessageId }` but asserts participation by deriving the peer from the socket context: the client also knows who they're reading, but the server trusts only `socket.data.userId` + the friendship graph. **Resolution:** `message:read` payload is `{ peerId, upToMessageId }` (NOT `conversationId`) — the server computes `conversationId(socketUser, peerId)` itself, asserts friendship, and emits `message:read` with the conversationId to the peer. This avoids trusting a client-supplied conversationId entirely. (Adjusts the §6 payload `{ conversationId, upToMessageId }` → `{ peerId, upToMessageId }` for the client→server direction; the server→client `message:read` event keeps `{ conversationId, upToMessageId }` as §6 specifies.)
- **No spoofing:** a client cannot mark another user's messages read, cannot deliver on behalf of another user, cannot emit `typing` as another user — every action is keyed to `socket.data.userId`.
- **`clientMsgId`** is returned in the `message:send` ack alongside `{ id, created_at }` so the client can reconcile its optimistic bubble. It is NOT persisted (see §7).

## 7. Explicit non-goals / deferred

- **`clientMsgId` persistence / dedup:** 2b does not persist `clientMsgId` and does not deduplicate sends. A retried `message:send` with the same `clientMsgId` creates a second message row. Dedup is a future hardening task (would need a `client_msg_id` column with a unique constraint per sender). 2b only returns `clientMsgId` in the ack for client-side reconciliation.
- **Group messaging** — v2.
- **Message editing/deletion** — not in v1.
- **Media/attachments** — v3.
- **`message:send` rate limiting** — the global `@fastify/rate-limit` covers REST; socket-event rate limiting (per-connection message throttling) is deferred. Note only; abuse is bounded by friends-only sending.
- **Offline delivery queue beyond Postgres:** messages to offline recipients simply sit in Postgres and are fetched via history on next connect (plus delivered live via `message:new` if the recipient connects while the sender is online). No Redis-backed offline queue.

## 8. Testing strategy

- **In-process Socket.IO tests** (reuse `test/helpers/realtime.ts` `makeRealtimeStack` + `socketClient` + `makeFriends`): two friends each with a socket. Assert:
  - `message:send` → sender ack `{ id, created_at }`; recipient receives `message:new` with the full message.
  - Recipient emits `message:delivered { messageId }` → sender receives `message:delivered { messageId, delivered_at }`; row's `delivered_at` is set.
  - `message:read` → peer receives `message:read { conversationId, upToMessageId }`; row's `read_at` set on the right messages (only recipient's received messages, not sender's own).
  - `typing:start`/`stop` → peer receives `typing { fromUserId, isTyping }`.
  - Non-friend `message:send` → error ack (no `message:new` to the target).
- **History REST test:** send several messages, then `GET /conversations/:peerId/messages` paginates newest-first, `before` cursor works, non-friend → 403.
- Tests run against Dockerized Postgres + Redis. Existing 34 tests must stay green.

## 9. Plan 3 (context only — NOT this plan)

The Electron/React client wires to the Plan 1 REST API + Plan 2a socket events + Plan 2b messaging events defined here. `keytar` stores the refresh token. The client emits `message:send`/`message:delivered`/`message:read`/`typing:*` and renders `message:new`/`message:delivered`/`message:read`/`typing`/`presence:update`.

---

## Self-review (author)

- **Spec coverage:** `message:send` (persist + ack + fan-out) ✔; `message:new` ✔; `message:delivered` (client-driven delivery hook) ✔; `message:read` (mark read + fan-out) ✔; `typing:start`/`stop` → `typing` ✔; `GET /conversations/:peerId/messages` paged history ✔; friends-only authz ✔; `(conversation, created_at)` paging ✔; `conversationId` reuse ✔; `messages` table reuse (no migration) ✔.
- **Divergence from parent spec §6 noted & justified:** §2 Decision 1 (client-driven `message:delivered` adds a client→server event); §6 (read payload changed from `{ conversationId, upToMessageId }` to `{ peerId, upToMessageId }` client→server to avoid trusting a client-supplied conversationId — server→client `message:read` keeps `{ conversationId, upToMessageId }`).
- **No migration needed** — `messages` table + index already exist from Plan 1.
- **No new infra/config** — composes on Plan 2a's `io` + `registry` + `pool`.
- **Ambiguity resolved:** read-receipt participant check (§6) — server computes conversationId from `socket.data.userId` + client-supplied `peerId`, never trusts a client conversationId.
- **`clientMsgId` scope** — ack-only, not persisted/deduped (§7), explicit.
