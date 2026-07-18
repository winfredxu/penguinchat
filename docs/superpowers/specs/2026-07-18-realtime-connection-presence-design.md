# PenguinChat Plan 2a — Real-time Connection Layer + Presence

- **Status:** design approved, pre-implementation
- **Date:** 2026-07-18
- **Parent spec:** `docs/system_design.md`

---

## 1. Scope

This plan adds the **real-time connection layer and presence system** to the PenguinChat backend. It activates the `session-registry` seam from Plan 1 (replacing the no-op with a Redis-backed Socket.IO implementation), adds the presence module, and wires live presence into the existing `/contacts` endpoint. **Messaging (send, receive, receipts, history, typing) is deferred to Plan 2b** — the socket layer and presence it builds on are messaging-ready.

### What this plan delivers

- Socket.IO server attached to the Fastify HTTP server, authenticated on handshake via JWT
- `@socket.io/redis-adapter` for cross-instance fan-out; each user joins a room named by their `userId` on connect
- `RedisSessionRegistry` replacing `NoopSessionRegistry` — `notify(userId, event, payload)` emits `io.to(userId).emit(event, payload)`, so Plan 1's `friend:request` / `friend:accepted` notifications now deliver live
- Presence module backed by Redis (`presence:{userId}` key with TTL), refreshed by `presence:heartbeat` events (~every 25s)
- Presence broadcasts: on connect → broadcast `presence:update {userId, "online"}` to the user's friends; on disconnect (if last socket cluster-wide) → broadcast `presence:update {userId, "offline"}`
- `GET /contacts` now returns real presence status instead of the hardcoded `"offline"`
- Redis connection config added to the app's `Config` type and `docker-compose.yml`

### Deliberately out of scope (Plan 2b)

- `message:send`, `message:new`, `message:delivered`, `message:read` — the messaging module
- `typing:start` / `typing:stop` — the typing module
- `GET /conversations/:userId/messages` — message history endpoint
- The `messaging` domain module and repo

---

## 2. Architecture additions

```
                                    ┌──────────────────────────────────────┐
                                    │        Backend (Node.js)               │
                                    │  ┌──────────────┐   ┌───────────────┐  │
                                    │  │ REST API     │   │ Socket.IO      │  │
                                    │  │ (Fastify)    │   │ gateway        │  │
                                    │  │ auth,contacts│   │ JWT handshake  │  │
                                    │  └──────┬───────┘   │ join userId rm │  │
                                    │         │           └───────┬───────┘  │
                                    │         │  domain services   │         │
                                    │  ┌──────┴────────────────────┴──────┐  │
                                    │  │ auth · contacts · presence ·     │  │
                                    │  │ session-registry (Redis impl)    │  │
                                    │  └──────┬───────────────────┬────────┘  │
                                    │         ▼                   ▼           │
                                    │   ┌───────────┐      ┌────────────┐     │
                                    │   │PostgreSQL │      │   Redis     │     │
                                    │   └───────────┘      │ adapter+pres│    │
                                    │                       └────────────┘     │
                                    └──────────────────────────────────────┘
```

### New components

- **Socket.IO gateway** (`src/realtime/gateway.ts`). Creates the `Server` instance, attaches `@socket.io/redis-adapter`, performs JWT handshake auth (reuses `verifyAccess` from `src/modules/auth/tokens.ts`), and on connect: joins the socket to room `userId`, sets the user online, and broadcasts `presence:update`. On disconnect: checks if the user has any remaining sockets cluster-wide (`io.in(userId).fetchSockets()`); if empty, clears presence and broadcasts offline. Registers event handlers for `presence:heartbeat` and `disconnect`.

- **Redis connection** (`src/realtime/redis.ts`). Creates two publisher/subscriber clients for the adapter plus one general client for presence operations. All three share the same `redisUrl` from config.

- **Presence module** (`src/modules/presence/`). `presence.service.ts` — `setOnline(userId)`, `setOffline(userId)`, `refreshTTL(userId)`, `getPresence(userId)`, `getPresenceMany(userIds[])`, `getFriendIds(userId)`. Backed by Redis key `presence:{userId}` with a 30-second TTL (refreshed by heartbeat; expires on disconnect). `presence.handlers.ts` — socket event wiring for heartbeat + connect/disconnect lifecycle.

- **Redis session-registry** (`src/modules/session-registry/redis-session-registry.ts`). Implements the existing `SessionRegistry` interface. `notify(userId, event, payload)` calls `io.to(userId).emit(event, payload)`. Uses a lazy-holder pattern for `io` (the Socket.IO server isn't available at `buildApp` time — see §3 below).

### Modified components

- **`src/app.ts`** — `AppDeps` gains an optional `redisUrl` field (required for Redis-backed services). The `buildApp` function accepts the Redis session-registry and the presence service via deps (or creates defaults).
- **`src/config.ts`** — `Config` gains `redisUrl: string`.
- **`src/server.ts`** — creates the Redis clients, creates `io` after `app.listen()`, attaches the adapter, calls `registry.attach(io)` and `gateway.attach(io)`.
- **`src/modules/contacts/contacts.service.ts`** — `listContacts` now reads real presence from the presence service instead of hardcoding `"offline"`. The presence service is injected.
- **`docker-compose.yml`** — `api` service environment gains `REDIS_URL`.

---

## 3. Lazy IO holder (chicken-and-egg resolution)

`buildApp` needs a `SessionRegistry` instance (so contacts routes can call `notify`), but the `io` server isn't created until after `app.listen()` (Socket.IO needs the raw HTTP server). Resolution:

```ts
class RedisSessionRegistry implements SessionRegistry {
  private io: Server | null = null;
  attach(io: Server) { this.io = io; }
  async notify(userId: string, event: string, payload: unknown): Promise<void> {
    if (!this.io) return; // pre-attach: silently drop (matches NoopSessionRegistry)
    this.io.to(userId).emit(event, payload);
  }
}
```

Startup order: `buildApp(deps)` → `app.listen()` → create `io` → `registry.attach(io)` → `gateway.attach(io)`. Between `buildApp` and `registry.attach`, `notify` calls silently drop — identical to the no-op Plan 1 behavior. No request can arrive before `listen` returns, so this window is harmless.

---

## 4. Presence details

### Redis keys

- `presence:{userId}` → `"online"`, TTL 30 seconds (refreshed by heartbeat)
- No `presence:{userId} = "away"` in this plan — presence is binary: online (key exists) or offline (key expired/absent). The `"away"` status is a UI refinement that can be added later with a separate key or value change.

### Heartbeat

Client emits `presence:heartbeat` approximately every 25 seconds. The server handler calls `refreshTTL(userId)`, which sets the key TTL back to 30 seconds. If the client crashes or the network drops, the key expires within 30 seconds. On reconnect, the connect handler immediately sets the user online.

### Broadcast

On connect: look up the user's friend IDs (via `contacts.repo.ts` `listFriends`), then emit `presence:update { userId, status: "online" }` to each friend's room (`io.to(friendId).emit(...)`). On disconnect (if last socket): same but `status: "offline"`.

### `/contacts` integration

`contacts.service.ts` `listContacts` currently maps each friend to `{ ...f, presence: "offline" as const }`. This changes to call `presenceService.getPresenceMany(friendIds)`, which returns a `Map<userId, "online" | "offline">` from a Redis `MGET` on all `presence:*` keys. Each friend gets their real status. The `Contact` type changes from `presence: "offline"` to `presence: "online" | "offline"`.

---

## 5. Socket.IO event surface (this plan)

**Client → server**

| Event | Payload | Notes |
|-------|---------|-------|
| `presence:heartbeat` | — | refreshes TTL |

**Server → client**

| Event | Payload | Meaning |
|-------|---------|---------|
| `presence:update` | `{ userId: string, status: "online" \| "offline" }` | friend status changed |
| `friend:request` | `{ request }` | someone added you (now live via registry) |
| `friend:accepted` | `{ friendship }` | they accepted you (now live via registry) |

Events deferred to Plan 2b: `message:send`, `message:new`, `message:delivered`, `message:read`, `typing:start`, `typing:stop`, `typing`.

---

## 6. Testing strategy

Socket.IO is harder to unit-test than REST routes. Approach:

- **Integration test helper** (`test/helpers/socket.ts`): creates a `Socket` client that connects to the running `io` server with a valid JWT. Exposes `emit`, `on`, `waitFor(event, timeout)`, `disconnect`.
- **Test server fixture** (`test/helpers/server.ts`): starts the full Fastify+io stack on a random port, returns the `app`, `io`, and port. Teardown in `afterAll`.
- Presence tests: connect → verify `presence:update` broadcast to a friend's socket; disconnect → verify offline broadcast; heartbeat → verify TTL refresh (check Redis key directly).
- Registry tests: `notify(userId, "friend:request", ...)` → client socket receives the event.
- Contacts REST test: `GET /contacts` after a friend comes online → response includes `presence: "online"`.

Tests run against the Dockerized Postgres and Redis. No mocking of Socket.IO internals.

---

## 7. File structure additions

```
src/
  config.ts                     # +redisUrl field
  app.ts                        # +presenceService dep, pass to contacts
  server.ts                     # +create io, attach adapter + registry + gateway
  realtime/
    redis.ts                    # createAdapter clients + general client
    gateway.ts                  # io server setup, auth, connect/disconnect/heartbeat
  modules/
    presence/
      presence.service.ts       # setOnline/clear/refresh/get/getMany/getFriendIds
      presence.handlers.ts      # socket event wiring
    session-registry/
      redis-session-registry.ts # RedisSessionRegistry implements SessionRegistry
  modules/contacts/
    contacts.service.ts         # inject presence, real status in listContacts
test/
  helpers/
    socket.ts                   # Socket.IO test client helper
    server.ts                   # full-stack test server fixture
  presence.test.ts
  session-registry.test.ts
  contacts-presence.test.ts
```
