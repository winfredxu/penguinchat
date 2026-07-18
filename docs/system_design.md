# PenguinChat — System Design

A QQ-style desktop instant-messaging application. This document covers the full
product vision and specifies **Phase 1 (v1 — Core chat)** in enough detail to
implement. Later phases are sketched so the v1 design leaves room for them.

- **Status:** design approved, pre-implementation
- **Date:** 2026-07-17
- **UI mockup:** `docs/ui-mockup.html` (rendered artifact)

---

## 1. Overview

PenguinChat is a cross-platform desktop chat app modeled on QQ. A user registers,
logs in, adds friends, sees who is online, and exchanges real-time text messages
that persist as history. The system is a modern web-stack real-time app: a
stateless REST API for request/response operations, a Socket.IO gateway for live
events, PostgreSQL as the source of truth, and Redis for presence and cross-instance
message fan-out.

**Design principle:** ship the tightest end-to-end slice first (core chat), behind
clean domain boundaries so groups, file transfer, and voice can be added as later
phases without rework.

### Roadmap

| Phase | Scope | Status |
|------|-------|--------|
| **v1** | Register/login, friends (add/accept/list), 1:1 real-time text, presence, message history | **This spec** |
| v2 | Group creation and group chat | Sketched |
| v3 | Image/file transfer | Sketched |
| v4 | WebRTC voice/video calls (real UDP path) | Sketched |

---

## 2. Technology stack

| Layer | Choice | Notes |
|------|--------|-------|
| Desktop client | **Electron + React** | Frameless window; native-app feel; cross-platform |
| Client state | React + a lightweight store (Zustand) | — |
| Secrets storage | `keytar` (OS keychain) | Stores JWT refresh token |
| REST API | **Node.js + Fastify** | Auth, friends, history |
| Real-time | **Socket.IO** | Live messages, presence, typing, receipts |
| Database | **PostgreSQL** | Source of truth |
| Cache / fan-out | **Redis** | Presence, socket map, pub/sub across instances |
| Auth | **JWT** (access + refresh), passwords via **argon2** | — |
| Packaging / deploy | **Docker** (backend), electron-builder (client) | Per project convention, backend always runs in Docker |

> **Transport rationale.** Modern chat apps (Discord, Slack, Signal desktop) use a
> persistent **WebSocket** for real-time traffic rather than hand-rolled TCP/UDP
> sockets. UDP re-enters only for real-time media via **WebRTC**, which is deferred
> to the voice phase (v4). v1 therefore uses REST + Socket.IO over TLS.

---

## 3. Architecture

```
┌───────────────────────────┐          ┌──────────────────────────────────────┐
│   Electron Desktop App     │          │        Backend (Node.js)               │
│                            │  HTTPS   │  ┌──────────────┐   ┌───────────────┐  │
│  Main process              │◄────────►│  │ REST API     │   │ Socket.IO      │  │
│   • Socket.IO client       │  (REST)  │  │ (Fastify)    │   │ gateway        │  │
│   • HTTP client            │          │  │ auth,friends,│   │ live msgs,     │  │
│   • JWT storage (keytar)   │   WSS    │  │ history      │   │ presence,typing│  │
│         ▲  IPC             │◄────────►│  └──────┬───────┘   └───────┬───────┘  │
│         ▼                  │(Socket.IO)│        │  domain services   │         │
│  Renderer (React)          │          │  ┌──────┴────────────────────┴──────┐  │
│   • QQ-style UI            │          │  │ auth · contacts · messaging ·     │  │
│                            │          │  │ presence · session-registry       │  │
└───────────────────────────┘          │  └──────┬───────────────────┬────────┘  │
                                        │         ▼                   ▼           │
                                        │   ┌───────────┐      ┌────────────┐     │
                                        │   │PostgreSQL │      │   Redis     │     │
                                        │   └───────────┘      └────────────┘     │
                                        └──────────────────────────────────────┘
```

### Components

- **REST API (Fastify).** Stateless request/response CRUD: register, login, token
  refresh, profile, friend requests, contact list, paged message history. Validates
  JWT access tokens.
- **Socket.IO gateway.** Authenticated on handshake with the JWT. Carries all live
  events (see §6). On connect it registers the socket in Redis; on disconnect it
  clears presence.
- **Domain services** (in-process modules, one clear responsibility each):
  - `auth` — registration, login, token issue/verify, password hashing
  - `contacts` — friend requests, friendship graph, contact listing
  - `messaging` — persist + route messages, delivery/read receipts, history paging
  - `presence` — online/away state, heartbeats, presence broadcasts
  - `session-registry` — user→socket mapping and pub/sub fan-out via Redis
- **PostgreSQL** — source of truth (§5).
- **Redis** — presence state (`presence:{userId}` w/ TTL), socket map
  (`sockets:{userId}`), and pub/sub channels (`events:{userId}`) so any instance can
  push to a user connected elsewhere.

These are in-process modules in v1 but have service-shaped boundaries, so they can be
extracted into separate processes if scaling demands it.

### Message delivery flow

1. Client emits `message:send`.
2. `messaging` persists the row to Postgres, then **acks the sender** with the real
   `id` and `created_at` (client reconciles its optimistic bubble via `clientMsgId`).
3. `session-registry` looks up `sockets:{recipientId}` in Redis.
4. If online, it publishes to `events:{recipientId}`; the instance holding that
   socket emits `message:new` and marks `delivered_at`.
5. If offline, the message simply stays in Postgres and is fetched on next login /
   history sync.

---

## 4. Domain boundaries (service seams)

| Module | Responsibility | Depends on |
|--------|----------------|------------|
| `auth` | Identity, credentials, tokens | Postgres |
| `contacts` | Friend requests + friendship graph | Postgres, session-registry (notify) |
| `messaging` | Message persistence, routing, receipts, history | Postgres, session-registry |
| `presence` | Online/away, heartbeat TTL, broadcasts | Redis, session-registry |
| `session-registry` | user↔socket map, cross-instance pub/sub | Redis |

---

## 5. Data model (PostgreSQL)

```sql
-- users
id            uuid PRIMARY KEY DEFAULT gen_random_uuid()
username      text UNIQUE NOT NULL            -- login handle (QQ "number")
display_name  text NOT NULL
password_hash text NOT NULL                   -- argon2
avatar_url    text
signature     text                            -- QQ-style status line
created_at    timestamptz NOT NULL DEFAULT now()

-- friendships (one row per pair; user_a < user_b by uuid to avoid duplicates)
id            uuid PRIMARY KEY DEFAULT gen_random_uuid()
user_a        uuid NOT NULL REFERENCES users(id)
user_b        uuid NOT NULL REFERENCES users(id)
created_at    timestamptz NOT NULL DEFAULT now()
UNIQUE (user_a, user_b)

-- friend_requests
id            uuid PRIMARY KEY DEFAULT gen_random_uuid()
from_user     uuid NOT NULL REFERENCES users(id)
to_user       uuid NOT NULL REFERENCES users(id)
message       text                            -- verification note
status        text NOT NULL CHECK (status IN ('pending','accepted','declined'))
created_at    timestamptz NOT NULL DEFAULT now()
-- partial unique: only one pending request per direction
CREATE UNIQUE INDEX ON friend_requests (from_user, to_user) WHERE status = 'pending';

-- messages
id            uuid PRIMARY KEY DEFAULT gen_random_uuid()
conversation  uuid NOT NULL                   -- deterministic id derived from the user pair
sender_id     uuid NOT NULL REFERENCES users(id)
recipient_id  uuid NOT NULL REFERENCES users(id)
body          text NOT NULL                   -- v1: text only
created_at    timestamptz NOT NULL DEFAULT now()
delivered_at  timestamptz
read_at       timestamptz
CREATE INDEX ON messages (conversation, created_at);
```

**Key choices**

- **Friendships one-row-per-pair** (ordered uuids) — no asymmetric or duplicate rows.
- **Deterministic `conversation` id** derived from the two user ids (e.g. UUIDv5 of
  the sorted pair) — history queries filter on one column, never an `OR`.

**Redis keys (ephemeral, not source of truth)**

- `presence:{userId}` → `online` | `away`, TTL refreshed by heartbeat
- `sockets:{userId}` → set of active socketIds (multi-device ready)
- pub/sub channel `events:{userId}` → live-event fan-out across instances

---

## 6. API & real-time surface

### REST

```
POST  /auth/register       {username, display_name, password} → {user, tokens}
POST  /auth/login          {username, password}               → {user, tokens}
POST  /auth/refresh        {refreshToken}                      → {tokens}
GET   /me                                                      → {user}
PATCH /me                  {display_name?, signature?, avatar?}→ {user}

GET   /contacts                                                → [friend + presence]
GET   /friend-requests                                         → [incoming pending]
POST  /friend-requests     {username, message}                 → {request}
POST  /friend-requests/:id/accept                              → {friendship}
POST  /friend-requests/:id/decline                             → {ok}

GET   /conversations/:userId/messages?before=&limit=50         → [messages]
```

### Socket.IO events (JWT-authenticated on handshake)

**Client → server**

| Event | Payload | Notes |
|-------|---------|-------|
| `message:send` | `{toUserId, body, clientMsgId}` | ack → `{id, created_at}` |
| `message:read` | `{conversationId, upToMessageId}` | marks read |
| `typing:start` / `typing:stop` | `{toUserId}` | — |
| `presence:heartbeat` | — | ~every 25s, refreshes TTL |

**Server → client**

| Event | Payload | Meaning |
|-------|---------|---------|
| `message:new` | `{message}` | incoming chat |
| `message:delivered` | `{messageId, delivered_at}` | your sent msg reached recipient |
| `message:read` | `{conversationId, upToMessageId}` | recipient read up to here |
| `presence:update` | `{userId, status}` | friend online / away |
| `typing` | `{fromUserId, isTyping}` | typing indicator |
| `friend:request` | `{request}` | someone added you |
| `friend:accepted` | `{friendship}` | they accepted you |

---

## 7. UI design

Full rendered mockup: `docs/ui-mockup.html`.

**Layout** — classic three-column IM under a frameless titlebar:
`66px icon rail · 300px conversation list · fluid chat panel`.

**Visual identity** (derived from QQ's penguin + sky identity, not a generic template):

- **Color:** `--sky #12B7F5` (primary), `--sky-deep #0A84C7` (gradient/hover),
  `--scarf #FF6B4A` (single warm accent — unread badges, send button), `--ink
  #17232E`, `--slate #6B7C8C`, `--cloud #EEF3F7` (ground), `--snow #FFFFFF`
  (surfaces). Full dark theme defined at token level.
- **Type:** rounded system face (`ui-rounded` / `SF Pro Rounded`) for names,
  headings, and the wordmark — its friendliness echoes the penguin; crisp system
  sans for body; tabular mono for timestamps and IDs. No web-font CDN (blocked by
  CSP / avoids silent fallback).
- **Signature element:** the **presence pulse** — online friends' avatars carry a
  soft breathing cyan halo — paired with the glossy sky-gradient **profile banner**
  showing avatar, name, signature line, and PenguinChat number. These are what the
  UI is remembered by. Motion respects `prefers-reduced-motion`.

**Core states to build:** login/register, contact list grouped by presence
(Online/Away/Offline) with unread badges, 1:1 chat with in/out bubbles + read ticks
+ typing indicator, add-friend flow, incoming friend-request notification.

---

## 8. Security

- Passwords hashed with **argon2id**; never logged or returned.
- **JWT** access tokens (short-lived, ~15 min) + refresh tokens (long-lived, rotated);
  refresh token stored in the OS keychain via `keytar`, never in plain files.
- Socket.IO handshake rejects connections without a valid access token.
- All authorization is server-side: a user may only read a conversation they are a
  participant in, and may only message existing friends.
- TLS on both HTTP and WebSocket in any non-local environment.
- Input validation at the REST/Socket boundary (schema validation on every payload).
- Rate-limit auth endpoints and `message:send` to blunt abuse.

---

## 9. Scalability

- **Stateless API + gateway.** Any instance serves any request; horizontal scaling
  behind a load balancer. Socket.IO uses the **Redis adapter** so an event for a user
  connected to instance B can be emitted from instance A.
- **Presence in Redis** with TTL — no sticky in-memory state; a crashed instance's
  users simply expire.
- **Postgres** handles chat history well into large scale; `(conversation,
  created_at)` index keeps paging fast. If message volume ever outgrows it, the
  `messages` table is the isolated piece to migrate to a wide-column store.
- **Multi-device** is already modeled (`sockets:{userId}` is a set), so fan-out to all
  of a user's devices needs no schema change.

---

## 10. Deferred (later phases)

- **v2 Groups:** `groups`, `group_members`, group-scoped `conversation` ids; Socket.IO
  rooms per group; the event surface generalizes from `toUserId` to a target.
- **v3 File transfer:** object storage (S3-compatible) + signed upload URLs; `messages`
  gains a `type` and `attachment` reference.
- **v4 Voice/video:** WebRTC with a signaling channel over the existing Socket.IO
  connection, plus STUN/TURN servers — this is where UDP returns.
```
