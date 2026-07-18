# PenguinChat Plan 2a — Real-time Connection Layer + Presence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Socket.IO real-time connection layer to the PenguinChat backend — JWT handshake auth, the Redis-backed `SessionRegistry` (activating Plan 1's no-op seam so `friend:request`/`friend:accepted` deliver live), and the presence subsystem (online/offline, heartbeat TTL, friend broadcasts), with `/contacts` returning real presence.

**Architecture:** A Socket.IO server attached to the Fastify HTTP server, using `@socket.io/redis-adapter` for cross-instance fan-out. Each connected socket joins a room named by its `userId`; `RedisSessionRegistry.notify(userId, event, payload)` emits `io.to(userId).emit(...)`. Presence is a Redis key `presence:{userId}` with a 30s TTL refreshed by `presence:heartbeat`. A lazy-`io` holder resolves the chicken-and-egg of `io` (needs `app.server`) vs. `registry` (needed inside `buildApp`).

**Tech Stack:** Node.js 20+, TypeScript (strict, ESM), Fastify 4, `socket.io` 4, `@socket.io/redis-adapter` 8, `redis` (node-redis v4), `socket.io-client` 4 (tests only), Vitest, Docker (Postgres 16 + Redis 7 already in compose).

## Global Constraints

- Backend **always runs in Docker**; tests connect to the Dockerized Postgres **and** Redis. Docker is user-managed: NEVER restart the daemon or run `open -a Docker`. If Docker is down, report BLOCKED — do not start it.
- The global npm cache has permission issues; if any task runs `npm`, first `export npm_config_cache=/tmp/claude-501/-Users-winfredxu-penguinchat/deb5185c-85bd-4194-808f-98b389c6dd23/scratchpad/npm-cache`.
- TypeScript strict mode, ESM (`type: module`), `.js` import specifiers.
- JWT handshake auth reuses `verifyAccess(token, cfg)` from `src/modules/auth/tokens.ts`; missing/invalid token ⇒ connection rejected.
- Authorization is server-side: the acting user identity is always `socket.data.userId` (from the verified JWT), never client-supplied.
- Presence TTL is **30 seconds**; client heartbeat fires **~every 25 seconds**. Presence values are `"online" | "offline"` only in 2a (no `"away"`).
- `password_hash` is never logged or returned (unchanged from Plan 1).
- Existing 20 Plan-1 tests must stay green throughout; no REST behavior changes except `/contacts` gaining real presence (which falls back to `"offline"` when no presence service is injected, preserving the old behavior).

---

## File Structure

```
src/
  config.ts                              # +redisUrl field + loadConfig
  app.ts                                 # AppDeps gains optional presence; pass to contacts
  server.ts                              # create redis clients, io after listen, attach registry+gateway
  realtime/
    redis.ts                             # createRedisClients(redisUrl) -> {pub, sub, general}
    gateway.ts                           # createGateway(server, deps) -> Socket.IO Server
  modules/
    presence/
      presence.service.ts                # PresenceService + PresenceReader interface + NoopPresenceService
      presence.handlers.ts               # connect/disconnect/heartbeat wiring
    session-registry/
      redis-session-registry.ts          # RedisSessionRegistry (lazy io holder)
    contacts/
      contacts.service.ts                # listContacts takes a PresenceReader
      contacts.routes.ts                 # pass presence reader through
test/
  helpers/
    app.ts                               # testConfig gains redisUrl
    realtime.ts                          # makeRealtimeStack() + socket client helper
  realtime.redis.test.ts
  session-registry.test.ts
  gateway.auth.test.ts
  presence.service.test.ts
  presence.broadcast.test.ts
  contacts-presence.test.ts
```

**Boundaries:** `realtime/` owns the socket server and Redis clients. `presence/` owns the online/offline state and the socket-lifecycle handlers that maintain it. `session-registry/redis-session-registry.ts` is the one implementation that bridges the domain services (which call `notify`) to the socket layer (which emits). `contacts.service` depends only on the `PresenceReader` interface, not on Redis or sockets.

---

## Task 1: Dependencies, Redis config, Redis clients, realtime test fixtures

**Files:**
- Modify: `package.json` (add `socket.io`, `@socket.io/redis-adapter`, `redis`; dev `socket.io-client`, `@types/socket.io-client`)
- Modify: `src/config.ts`, `src/server.ts` (no-op wiring yet), `docker-compose.yml`, `.env.example`
- Create: `src/realtime/redis.ts`, `test/helpers/realtime.ts`
- Modify: `test/helpers/app.ts` (add `redisUrl` to `testConfig`)
- Create: `test/realtime.redis.test.ts`

**Interfaces:**
- Consumes: `Config` from `src/config.ts` (Task 1 of Plan 1).
- Produces:
  - `Config` gains `redisUrl: string`; `loadConfig()` reads `REDIS_URL` (required).
  - `createRedisClients(redisUrl: string): Promise<{ pub: RedisClientType; sub: RedisClientType; general: RedisClientType }>` from `src/realtime/redis.ts` — three connected node-redis clients (`pub` and `sub` are separate for the adapter; `general` is for presence). Each client is `await client.connect()`-ed. Callers must `quit()` all three on teardown.
  - `makeRealtimeStack(): Promise<RealtimeStack>` from `test/helpers/realtime.ts` where `RealtimeStack = { app, io, port, registry, presence, cleanup }`. Builds the full Fastify+io stack on port 0 against the Dockerized Postgres+Redis, ready for socket tests. (Used by Tasks 2–6.)
  - `socketClient(port, token): Promise<Socket>` helper in `test/helpers/realtime.ts` — connects a `socket.io-client` to `http://localhost:${port}` with `{ auth: { token } }`, resolves on connect, rejects on `connect_error`.

- [ ] **Step 1: Add dependencies**

```bash
export npm_config_cache=/tmp/claude-501/-Users-winfredxu-penguinchat/deb5185c-85bd-4194-808f-98b389c6dd23/scratchpad/npm-cache
npm install socket.io@^4.7.5 @socket.io/redis-adapter@^8.3.0 redis@^4.6.7
npm install -D socket.io-client@^4.7.5 @types/socket.io-client@^3.0.0
```

- [ ] **Step 2: Add `redisUrl` to `src/config.ts`**

Replace the `Config` interface and `loadConfig` body with:

```ts
export interface Config {
  port: number;
  databaseUrl: string;
  redisUrl: string;
  jwtAccessSecret: string;
  jwtRefreshSecret: string;
  accessTtl: string;
  refreshTtl: string;
}

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

export function loadConfig(): Config {
  return {
    port: Number(process.env.PORT ?? 3000),
    databaseUrl: required("DATABASE_URL"),
    redisUrl: required("REDIS_URL"),
    jwtAccessSecret: required("JWT_ACCESS_SECRET"),
    jwtRefreshSecret: required("JWT_REFRESH_SECRET"),
    accessTtl: process.env.ACCESS_TTL ?? "15m",
    refreshTtl: process.env.REFRESH_TTL ?? "30d",
  };
}
```

- [ ] **Step 3: Update `.env.example`** — append:

```
REDIS_URL=redis://localhost:6379
```

- [ ] **Step 4: Update `docker-compose.yml`** — add `REDIS_URL` to the `api` service `environment`:

```yaml
      REDIS_URL: redis://redis:6379
```

- [ ] **Step 5: Create `src/realtime/redis.ts`**

```ts
import { createClient, type RedisClientType } from "redis";

export interface RedisClients {
  pub: RedisClientType;
  sub: RedisClientType;
  general: RedisClientType;
}

export async function createRedisClients(redisUrl: string): Promise<RedisClients> {
  const pub = createClient({ url: redisUrl }) as RedisClientType;
  const sub = pub.duplicate() as RedisClientType;
  const general = pub.duplicate() as RedisClientType;
  await Promise.all([pub.connect(), sub.connect(), general.connect()]);
  return { pub, sub, general };
}

export async function closeRedisClients(c: RedisClients): Promise<void> {
  await Promise.all([c.pub.quit(), c.sub.quit(), c.general.quit()]);
}
```

- [ ] **Step 6: Update `test/helpers/app.ts`** — add `redisUrl` to `testConfig`:

```ts
export const testConfig: Config = {
  port: 0,
  databaseUrl: TEST_DB_URL,
  redisUrl: process.env.REDIS_URL ?? "redis://localhost:6379",
  jwtAccessSecret: "test-access",
  jwtRefreshSecret: "test-refresh",
  accessTtl: "15m",
  refreshTtl: "30d",
};
```

- [ ] **Step 7: Create `test/helpers/realtime.ts`**

This fixture builds the full stack. It references `RedisSessionRegistry` (Task 2), `PresenceService` (Task 4), and `createGateway` (Task 3) — all created in later tasks. **For Task 1**, define the helper with the types it will use and `// @ts-expect-error`-free forward imports by importing them; the file will not typecheck until Tasks 2–4 land. To keep Task 1 independently testable, **write a minimal version now** that only builds the Fastify app + Redis clients + a bare `io` (no gateway/registry/presence yet), and extend it in later tasks. Minimal version:

```ts
import { io as ioc, type Socket as ClientSocket } from "socket.io-client";
import { Server } from "socket.io";
import { makePool, testConfig } from "./app.js";
import { resetDb } from "./db.js";
import { runMigrations } from "../../src/db/migrate.js";
import { createRedisClients, closeRedisClients } from "../../src/realtime/redis.js";

export interface RealtimeStack {
  app: Awaited<ReturnType<typeof import("../../src/app.js").buildApp>>;
  io: Server;
  port: number;
  cleanup: () => Promise<void>;
}

export async function makeRealtimeStack(): Promise<RealtimeStack> {
  const pool = makePool();
  await runMigrations(pool);
  await resetDb(pool);
  const redis = await createRedisClients(testConfig.redisUrl);
  const { buildApp } = await import("../../src/app.js");
  const app = await buildApp({ pool, config: testConfig });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const io = new Server(app.server, { cors: { origin: "*" } });
  return {
    app,
    io,
    port,
    cleanup: async () => {
      io.close();
      await app.close();
      await closeRedisClients(redis);
      await pool.end();
    },
  };
}

export function socketClient(port: number, token: string): Promise<ClientSocket> {
  return new Promise((resolve, reject) => {
    const sock = ioc(`http://localhost:${port}`, { auth: { token } });
    sock.on("connect", () => resolve(sock));
    sock.on("connect_error", (err) => {
      sock.disconnect();
      reject(err);
    });
  });
}

/** Register a user via REST and return { id, accessToken }. */
export async function registerUser(
  app: RealtimeStack["app"],
  username: string
): Promise<{ id: string; accessToken: string }> {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  const body = res.json();
  return { id: body.user.id, accessToken: body.tokens.accessToken };
}
```

- [ ] **Step 8: Write the failing test — `test/realtime.redis.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import { createRedisClients, closeRedisClients } from "../src/realtime/redis.js";

test("createRedisClients connects and PINGs", async () => {
  const c = await createRedisClients("redis://localhost:6379");
  const pong = await c.general.ping();
  expect(pong).toBe("PONG");
  await closeRedisClients(c);
});
```

- [ ] **Step 9: Run it**

Run: `npm test -- test/realtime.redis.test.ts`
Expected: PASS. (Requires Docker Postgres+Redis up. If Docker is down, report BLOCKED.)

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(2a): add realtime deps, redis config, redis clients, test fixtures"
```

---

## Task 2: RedisSessionRegistry (lazy `io` holder)

**Files:**
- Create: `src/modules/session-registry/redis-session-registry.ts`
- Create: `test/session-registry.test.ts`

**Interfaces:**
- Consumes: `SessionRegistry` interface from `src/modules/session-registry/session-registry.ts` (Plan 1); `Server` from `socket.io`.
- Produces: `RedisSessionRegistry implements SessionRegistry`:
  - `attach(io: Server): void`
  - `async notify(userId: string, event: string, payload: unknown): Promise<void>` — if `io` not yet attached, silently returns (matches Plan 1 no-op); otherwise `io.to(userId).emit(event, payload)`.

- [ ] **Step 1: Write the failing test — `test/session-registry.test.ts`**

This task tests only the **lazy no-op behavior**, which is deterministic and needs no socket. The "notify actually delivers to a room-joined socket" assertion lands in Task 3, where the gateway exists to authenticate a connection.

```ts
import { expect, test } from "vitest";
import { RedisSessionRegistry } from "../src/modules/session-registry/redis-session-registry.js";

test("notify before attach is a silent no-op (does not throw)", async () => {
  const registry = new RedisSessionRegistry();
  await expect(
    registry.notify("any-user", "friend:request", { x: 1 })
  ).resolves.toBeUndefined();
});

test("attach stores the io server without error", () => {
  const registry = new RedisSessionRegistry();
  // attach accepts a Server; pass a minimal stand-in typed as the interface expects.
  // (Full delivery is exercised in test/gateway.auth.test.ts, Task 3.)
  const fakeIo = { to: () => ({ emit: () => {} }) } as unknown as import("socket.io").Server;
  registry.attach(fakeIo);
  // After attach, notify routes through io.to().emit() — verify it still resolves.
  expect(registry.notify("u", "e", {})).resolves.toBeUndefined();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/session-registry.test.ts`
Expected: FAIL — `RedisSessionRegistry` not found.

- [ ] **Step 3: Create `src/modules/session-registry/redis-session-registry.ts`**

```ts
import type { Server } from "socket.io";
import type { SessionRegistry } from "./session-registry.js";

/**
 * Redis-backed session registry. Emits to the user's room via the Socket.IO
 * server; the @socket.io/redis-adapter (installed on `io` by the gateway) fans
 * the emit out across all instances and all of the user's devices.
 *
 * `io` is attached lazily because the Socket.IO server is not created until
 * after app.listen() (it needs the raw HTTP server). Before attach, notify is
 * a silent no-op — identical to Plan 1's NoopSessionRegistry. No request can
 * arrive before listen() returns, so this window is harmless.
 */
export class RedisSessionRegistry implements SessionRegistry {
  private io: Server | null = null;

  attach(io: Server): void {
    this.io = io;
  }

  async notify(userId: string, event: string, payload: unknown): Promise<void> {
    if (!this.io) return;
    this.io.to(userId).emit(event, payload);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/session-registry.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(2a): RedisSessionRegistry with lazy io holder"
```

---

## Task 3: Socket.IO gateway — handshake auth + room join

**Files:**
- Create: `src/realtime/gateway.ts`
- Modify: `test/helpers/realtime.ts` (have `makeRealtimeStack` use `createGateway`)
- Create: `test/gateway.auth.test.ts`

**Interfaces:**
- Consumes: `Config` (`jwtAccessSecret`), `verifyAccess(token, cfg)` from `src/modules/auth/tokens.ts`, `createAdapter` from `@socket.io/redis-adapter`, Redis `pub`/`sub` clients (Task 1).
- Produces: `createGateway(server: http.Server, deps: { config: Config; pub: RedisClientType; sub: RedisClientType }): Server`:
  - Creates `new Server(server, { cors: { origin: "*" } })`.
  - Installs the adapter: `io.adapter(createAdapter(deps.pub, deps.sub))`.
  - Handshake middleware: reads `socket.handshake.auth.token`; calls `verifyAccess`; on failure calls `next(new Error("unauthorized"))`; on success sets `socket.data.userId = sub` and calls `next()`.
  - On `"connection"`: `socket.join(socket.data.userId)`.
  - Returns `io`. (Presence handlers are wired in Task 5; this task only does auth + join.)

- [ ] **Step 1: Write the failing test — `test/gateway.auth.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import { makeRealtimeStack, socketClient, registerUser, type RealtimeStack } from "./helpers/realtime.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("valid JWT connects and the socket joins its userId room", async () => {
  stack = await makeRealtimeStack();
  const { accessToken, id } = await registerUser(stack.app, "alice");
  const sock = await socketClient(stack.port, accessToken);
  expect(sock.connected).toBe(true);
  // The server-side socket should be in the room named by the userId.
  const inRoom = await stack.io.in(id).fetchSockets();
  expect(inRoom.length).toBe(1);
  sock.disconnect();
});

test("registry.notify delivers an event to the connected user's socket", async () => {
  // Exercises the RedisSessionRegistry's real emit path now that the gateway
  // authenticates + room-joins the socket (Task 2 only tested the lazy no-op).
  const { RedisSessionRegistry } = await import("../src/modules/session-registry/redis-session-registry.js");
  const registry = new RedisSessionRegistry();
  registry.attach(stack.io);
  const { accessToken, id } = await registerUser(stack.app, "bob");
  const sock = await socketClient(stack.port, accessToken);
  const received = new Promise((r) => sock.on("friend:request", r));
  await registry.notify(id, "friend:request", { request: { id: "r1" } });
  expect(await received).toEqual({ request: { id: "r1" } });
  sock.disconnect();
});

test("missing token is rejected", async () => {
  await expect(socketClient(stack.port, "")).rejects.toThrow();
});

test("invalid token is rejected", async () => {
  await expect(socketClient(stack.port, "not-a-jwt")).rejects.toThrow();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/gateway.auth.test.ts`
Expected: FAIL — `createGateway` not found, and the stack fixture doesn't wire it yet.

- [ ] **Step 3: Create `src/realtime/gateway.ts`**

```ts
import type { Server } from "socket.io";
import { Server as IoServer } from "socket.io";
import { createAdapter } from "@socket.io/redis-adapter";
import type { Server as HttpServer } from "node:http";
import type { Config } from "../config.js";
import type { RedisClientType } from "redis";
import { verifyAccess } from "../modules/auth/tokens.js";

export interface GatewayDeps {
  config: Config;
  pub: RedisClientType;
  sub: RedisClientType;
}

export function createGateway(server: HttpServer, deps: GatewayDeps): Server {
  const io = new IoServer(server, { cors: { origin: "*" } });
  io.adapter(createAdapter(deps.pub, deps.sub));

  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token || typeof token !== "string") {
      return next(new Error("unauthorized"));
    }
    try {
      const { sub } = verifyAccess(token, deps.config);
      socket.data.userId = sub;
      next();
    } catch {
      return next(new Error("unauthorized"));
    }
  });

  io.on("connection", (socket) => {
    socket.join(socket.data.userId as string);
  });

  return io;
}
```

- [ ] **Step 4: Modify `test/helpers/realtime.ts` — use `createGateway` and return `io` from it**

Replace the `makeRealtimeStack` body's `io` creation with:

```ts
  const redis = await createRedisClients(testConfig.redisUrl);
  const { buildApp } = await import("../../src/app.js");
  const app = await buildApp({ pool, config: testConfig });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const { createGateway } = await import("../../src/realtime/gateway.js");
  const io = createGateway(app.server, { config: testConfig, pub: redis.pub, sub: redis.sub });
```

Keep `cleanup` closing `io`, `app`, redis, pool.

- [ ] **Step 5: Run the test to verify it passes**

Run: `npm test -- test/gateway.auth.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(2a): socket.io gateway with JWT handshake auth + room join"
```

---

## Task 4: Presence service (Redis-backed)

**Files:**
- Create: `src/modules/presence/presence.service.ts`
- Create: `test/presence.service.test.ts`

**Interfaces:**
- Consumes: a node-redis `general` client (Task 1).
- Produces:
  - `PresenceStatus = "online" | "offline"`.
  - `PresenceReader` interface: `getMany(userIds: string[]): Promise<Map<string, PresenceStatus>>`.
  - `PresenceService` class:
    - constructor `(general: RedisClientType, ttlSeconds = 30)`.
    - `setOnline(userId: string): Promise<void>` — `SET presence:{userId} online EX {ttl}`.
    - `refresh(userId: string): Promise<void>` — `EXPIRE presence:{userId} {ttl}` (no-op if absent — `EXPIRE` returns 0, which is fine).
    - `clear(userId: string): Promise<void>` — `DEL presence:{userId}`.
    - `get(userId: string): Promise<PresenceStatus>` — `GET` → `"online"` if present else `"offline"`.
    - `getMany(userIds: string[]): Promise<Map<string, PresenceStatus>>` — `MGET` over `presence:{id}` for each.
  - `NoopPresenceService` class implementing `PresenceReader`: `getMany` returns a Map of all `"offline"`. Used as the default when no Redis is wired (preserves Plan 1 behavior in existing tests).

- [ ] **Step 1: Write the failing test — `test/presence.service.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import { createRedisClients, closeRedisClients } from "../src/realtime/redis.js";
import { PresenceService, NoopPresenceService } from "../src/modules/presence/presence.service.js";

const clients = await createRedisClients("redis://localhost:6379");
afterAll(async () => { await closeRedisClients(clients); });

test("setOnline then get returns online; clear returns offline", async () => {
  const ps = new PresenceService(clients.general, 30);
  const id = "22222222-2222-2222-2222-222222222222";
  await ps.setOnline(id);
  expect(await ps.get(id)).toBe("online");
  await ps.clear(id);
  expect(await ps.get(id)).toBe("offline");
});

test("getMany returns a map keyed by userId", async () => {
  const ps = new PresenceService(clients.general, 30);
  const a = "33333333-3333-3333-3333-333333333333";
  const b = "44444444-4444-4444-4444-444444444444";
  await ps.setOnline(a);
  await ps.clear(b);
  const map = await ps.getMany([a, b]);
  expect(map.get(a)).toBe("online");
  expect(map.get(b)).toBe("offline");
});

test("refresh extends the TTL (key still present after a refresh)", async () => {
  const ps = new PresenceService(clients.general, 30);
  const id = "55555555-5555-5555-5555-555555555555";
  await ps.setOnline(id);
  await ps.refresh(id);
  expect(await ps.get(id)).toBe("online");
  await ps.clear(id);
});

test("NoopPresenceService returns offline for everyone", async () => {
  const noop = new NoopPresenceService();
  const map = await noop.getMany(["a", "b"]);
  expect(map.get("a")).toBe("offline");
  expect(map.get("b")).toBe("offline");
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/presence.service.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Create `src/modules/presence/presence.service.ts`**

```ts
import type { RedisClientType } from "redis";

export type PresenceStatus = "online" | "offline";

export interface PresenceReader {
  getMany(userIds: string[]): Promise<Map<string, PresenceStatus>>;
}

const key = (userId: string) => `presence:${userId}`;

export class PresenceService implements PresenceReader {
  constructor(private general: RedisClientType, private ttlSeconds = 30) {}

  async setOnline(userId: string): Promise<void> {
    await this.general.set(key(userId), "online", { EX: this.ttlSeconds });
  }

  async refresh(userId: string): Promise<void> {
    await this.general.expire(key(userId), this.ttlSeconds);
  }

  async clear(userId: string): Promise<void> {
    await this.general.del(key(userId));
  }

  async get(userId: string): Promise<PresenceStatus> {
    const v = await this.general.get(key(userId));
    return v === "online" ? "online" : "offline";
  }

  async getMany(userIds: string[]): Promise<Map<string, PresenceStatus>> {
    if (userIds.length === 0) return new Map();
    const keys = userIds.map(key);
    const vals = await this.general.mGet(keys);
    const out = new Map<string, PresenceStatus>();
    userIds.forEach((id, i) => {
      out.set(id, vals[i] === "online" ? "online" : "offline");
    });
    return out;
  }
}

export class NoopPresenceService implements PresenceReader {
  async getMany(userIds: string[]): Promise<Map<string, PresenceStatus>> {
    const m = new Map<string, PresenceStatus>();
    for (const id of userIds) m.set(id, "offline");
    return m;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `npm test -- test/presence.service.test.ts`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat(2a): presence service backed by redis with TTL"
```

---

## Task 5: Presence handlers + friend broadcasts

**Files:**
- Create: `src/modules/presence/presence.handlers.ts`
- Modify: `src/realtime/gateway.ts` (accept a `presence` + `pool` dep; wire connection/disconnect/heartbeat)
- Modify: `test/helpers/realtime.ts` (pass presence + pool into `createGateway`)
- Create: `test/presence.broadcast.test.ts`

**Interfaces:**
- Consumes: `PresenceService` (Task 4), `Pool` + `listFriends(pool, userId)` (Plan 1), `Server` (socket.io).
- Produces: `registerPresenceHandlers(io, deps: { presence: PresenceService; pool: Pool }): void` from `presence.handlers.ts`:
  - On `"connection"`: `await presence.setOnline(userId)`; look up friend ids via `listFriends(pool, userId)`; for each friend `io.to(friendId).emit("presence:update", { userId, status: "online" })`.
  - On `socket.on("presence:heartbeat")`: `await presence.refresh(socket.data.userId)`.
  - On `socket.on("disconnect")`: `const remaining = await io.in(userId).fetchSockets()`; if `remaining.length === 0`, `await presence.clear(userId)` and broadcast `presence:update { userId, status: "offline" }` to the user's friends. If non-empty (another device online), do nothing.
  - `createGateway` gains `presence: PresenceService` and `pool: Pool` in its deps and calls `registerPresenceHandlers(io, { presence, pool })` before returning `io`.

- [ ] **Step 1: Write the failing test — `test/presence.broadcast.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  socketClient,
  registerUser,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { acceptFriendRequest } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("connecting broadcasts presence:update online to a friend", async () => {
  stack = await makeRealtimeStack();
  const alice = await registerUser(stack.app, "alice");
  const bob = await registerUser(stack.app, "bob");
  await acceptFriendRequest(stack.app, alice, bob);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const seen = new Promise((r) => bobSock.on("presence:update", r));
  await socketClient(stack.port, alice.accessToken);
  const msg: any = await seen;
  expect(msg.userId).toBe(alice.id);
  expect(msg.status).toBe("online");
  bobSock.disconnect();
});

test("last disconnect broadcasts presence:update offline to a friend", async () => {
  const alice = await registerUser(stack.app, "alice2");
  const bob = await registerUser(stack.app, "bob2");
  await acceptFriendRequest(stack.app, alice, bob);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const offlineSeen = new Promise((r) => bobSock.on("presence:update", r));
  aliceSock.disconnect();
  // First event may be the online broadcast; wait specifically for offline.
  let last: any;
  bobSock.on("presence:update", (m) => { last = m; });
  const offline = await new Promise((resolve) => {
    const t = setInterval(() => { if (last && last.status === "offline") { clearInterval(t); resolve(last); } }, 50);
  });
  expect(offline.userId).toBe(alice.id);
  expect(offline.status).toBe("offline");
  bobSock.disconnect();
});
```

> The `acceptFriendRequest` helper (create it here in `test/helpers/friends.ts`) registers two users and has `to` accept `from`'s request, returning void. Implement it as:

```ts
// test/helpers/friends.ts
import type { FastifyInstance } from "fastify";

export interface RegisteredUser { id: string; accessToken: string; }

export async function acceptFriendRequest(
  app: FastifyInstance,
  from: RegisteredUser,
  to: RegisteredUser
): Promise<void> {
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: { authorization: `Bearer ${from.accessToken}` },
    payload: { username: "x" }, // placeholder, replaced below
  });
  // Resolve the recipient's username from their id is not needed — re-send by username.
  // Simpler: the helper takes usernames. Adjust the test to pass usernames instead.
  void send;
}
```

Because the contacts API keys friend requests off `username` (not id), make `acceptFriendRequest` take the recipient's **username**. Revise the helper and the test calls:

```ts
// test/helpers/friends.ts
import type { FastifyInstance } from "fastify";

export interface RegisteredUser { id: string; accessToken: string; username: string; }

import { registerUser } from "./realtime.js";

export async function makeFriends(
  app: FastifyInstance,
  aUsername: string,
  bUsername: string
): Promise<{ a: RegisteredUser; b: RegisteredUser }> {
  const a = await registerUser(app, aUsername);
  const b = await registerUser(app, bUsername);
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: { authorization: `Bearer ${a.accessToken}` },
    payload: { username: b.username },
  });
  const requestId = send.json().request.id;
  await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: { authorization: `Bearer ${b.accessToken}` },
  });
  return { a, b };
}
```

Update `registerUser` in `test/helpers/realtime.ts` to also return `username`:

```ts
export async function registerUser(app, username: string) {
  const res = await app.inject({ method: "POST", url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" } });
  const body = res.json();
  return { id: body.user.id, accessToken: body.tokens.accessToken, username };
}
```

And rewrite the broadcast test to use `makeFriends`:

```ts
import { makeFriends } from "./helpers/friends.js";
// ...
test("connecting broadcasts presence:update online to a friend", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const seen = new Promise((r) => bobSock.on("presence:update", r));
  await socketClient(stack.port, alice.accessToken);
  const msg: any = await seen;
  expect(msg.userId).toBe(alice.id);
  expect(msg.status).toBe("online");
  bobSock.disconnect();
});
```

(Apply the same `makeFriends` pattern to the offline test.)

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/presence.broadcast.test.ts`
Expected: FAIL — handlers not wired; no `presence:update` emitted.

- [ ] **Step 3: Create `src/modules/presence/presence.handlers.ts`**

```ts
import type { Server, Socket } from "socket.io";
import type { Pool } from "pg";
import { listFriends } from "../contacts/contacts.repo.js";
import type { PresenceService } from "./presence.service.js";

export interface PresenceHandlerDeps {
  presence: PresenceService;
  pool: Pool;
}

async function friendIds(pool: Pool, userId: string): Promise<string[]> {
  const friends = await listFriends(pool, userId);
  return friends.map((f) => f.id);
}

export function registerPresenceHandlers(io: Server, deps: PresenceHandlerDeps): void {
  const { presence, pool } = deps;

  io.on("connection", async (socket: Socket) => {
    const userId = socket.data.userId as string;

    await presence.setOnline(userId);
    const friends = await friendIds(pool, userId);
    for (const fid of friends) {
      io.to(fid).emit("presence:update", { userId, status: "online" });
    }

    socket.on("presence:heartbeat", async () => {
      await presence.refresh(userId);
    });

    socket.on("disconnect", async () => {
      const remaining = await io.in(userId).fetchSockets();
      if (remaining.length > 0) return; // another device still online
      await presence.clear(userId);
      const friends = await friendIds(pool, userId);
      for (const fid of friends) {
        io.to(fid).emit("presence:update", { userId, status: "offline" });
      }
    });
  });
}
```

- [ ] **Step 4: Modify `src/realtime/gateway.ts` — add `presence` + `pool` deps and call `registerPresenceHandlers`**

Update `GatewayDeps` and `createGateway`:

```ts
import type { PresenceService } from "../modules/presence/presence.service.js";
import { registerPresenceHandlers } from "../modules/presence/presence.handlers.js";
import type { Pool } from "pg";

export interface GatewayDeps {
  config: Config;
  pub: RedisClientType;
  sub: RedisClientType;
  presence: PresenceService;
  pool: Pool;
}
```

Inside `createGateway`, after the `io.on("connection", (socket) => { socket.join(...) })` block (keep the join), add:

```ts
  registerPresenceHandlers(io, { presence: deps.presence, pool: deps.pool });
```

(Keep the existing `io.on("connection")` that joins the room — both handlers run; Socket.IO supports multiple connection listeners. Alternatively, move the `socket.join` into `registerPresenceHandlers`. Pick: move the join into the handlers' connection listener to keep one listener. Replace the gateway's `io.on("connection")` block with the single call to `registerPresenceHandlers`, and add `socket.join(userId)` as the first line inside the handlers' connection listener.)

Final gateway connection section:

```ts
  registerPresenceHandlers(io, { presence: deps.presence, pool: deps.pool });
  return io;
```

And in `presence.handlers.ts` connection listener, first line:

```ts
    socket.join(userId);
```

- [ ] **Step 5: Modify `test/helpers/realtime.ts` — pass `presence` + `pool` into `createGateway`**

```ts
  const { PresenceService } = await import("../../src/modules/presence/presence.service.js");
  const presence = new PresenceService(redis.general, 30);
  const io = createGateway(app.server, {
    config: testConfig,
    pub: redis.pub,
    sub: redis.sub,
    presence,
    pool,
  });
```

Expose `presence` on `RealtimeStack` (add to the interface and return object) so tests can assert on Redis keys if needed.

- [ ] **Step 6: Run the test to verify it passes**

Run: `npm test -- test/presence.broadcast.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(2a): presence handlers — online/offline broadcasts + heartbeat"
```

---

## Task 6: `/contacts` real presence + wire it all in `server.ts`

**Files:**
- Modify: `src/app.ts` (`AppDeps` gains optional `presence?: PresenceReader`; pass to contacts routes)
- Modify: `src/modules/contacts/contacts.service.ts` (`listContacts` takes a `PresenceReader`)
- Modify: `src/modules/contacts/contacts.routes.ts` (pass presence through)
- Modify: `src/server.ts` (create redis clients + presence + RedisSessionRegistry; pass `registry` + `presence` into `buildApp`; after listen, create io via `createGateway`, `registry.attach(io)`)
- Modify: `test/helpers/realtime.ts` (pass `registry` into `buildApp` and `registry.attach(io)` after creating the gateway)
- Create: `test/contacts-presence.test.ts`

**Interfaces:**
- Consumes: `PresenceReader` + `NoopPresenceService` (Task 4), `RedisSessionRegistry` (Task 2), `createGateway` (Task 5).
- Produces:
  - `listContacts(pool, presence: PresenceReader, userId)` — fetches friends, `MGET`s their presence, returns `Contact[]` with real status.
  - `buildApp` `AppDeps` gains `presence?: PresenceReader`; when absent, `buildApp` uses `new NoopPresenceService()` (preserves Plan 1 behavior — existing tests unaffected).
  - `server.ts` wires the real stack: redis clients → `PresenceService` → `RedisSessionRegistry` → `buildApp({ pool, config, registry, presence })` → `app.listen` → `createGateway` → `registry.attach(io)`.

- [ ] **Step 1: Write the failing test — `test/contacts-presence.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import { makeRealtimeStack, socketClient, type RealtimeStack } from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("GET /contacts reflects a friend's real online presence", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  // Bob offline initially.
  let res = await stack.app.inject({
    method: "GET", url: "/contacts",
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.json().find((c: any) => c.username === "bob").presence).toBe("offline");
  // Bob comes online.
  const bobSock = await socketClient(stack.port, bob.accessToken);
  await new Promise((r) => setTimeout(r, 100)); // let the online broadcast settle in Redis
  res = await stack.app.inject({
    method: "GET", url: "/contacts",
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.json().find((c: any) => c.username === "bob").presence).toBe("online");
  bobSock.disconnect();
});
```

- [ ] **Step 2: Run it to verify it fails**

Run: `npm test -- test/contacts-presence.test.ts`
Expected: FAIL — `/contacts` still returns `"offline"` for everyone (hardcoded).

- [ ] **Step 3: Modify `src/modules/contacts/contacts.service.ts`**

Change `listContacts` to accept a `PresenceReader` and fill real status. Add the import and replace the function:

```ts
import type { PresenceReader, PresenceStatus } from "../presence/presence.service.js";

export async function listContacts(
  pool: Pool,
  presence: PresenceReader,
  userId: string
): Promise<Contact[]> {
  const friends = await listFriends(pool, userId);
  if (friends.length === 0) return [];
  const statusMap = await presence.getMany(friends.map((f) => f.id));
  return friends.map((f) => ({
    ...f,
    presence: statusMap.get(f.id) ?? ("offline" as PresenceStatus),
  }));
}
```

(Leave the `Contact` type as `PublicUser & { presence: "online" | "away" | "offline" }` — unchanged; `"away"` remains unused in 2a.)

- [ ] **Step 4: Modify `src/modules/contacts/contacts.routes.ts`**

The route options must carry a `presence: PresenceReader`. Update the `Opts` interface and the `listContacts` call:

```ts
import type { PresenceReader } from "../presence/presence.service.js";

interface Opts {
  pool: Pool;
  registry: SessionRegistry;
  presence: PresenceReader;
}
// ...
  app.get("/contacts", { preHandler: app.requireAuth }, async (req) => {
    return listContacts(pool, opts.presence, req.userId!);
  });
```

- [ ] **Step 5: Modify `src/app.ts` — add optional `presence` to `AppDeps` and default it**

```ts
import type { PresenceReader } from "./modules/presence/presence.service.js";
import { NoopPresenceService } from "./modules/presence/presence.service.js";

export interface AppDeps {
  pool: Pool;
  config: Config;
  registry?: SessionRegistry;
  presence?: PresenceReader;
}
```

Inside `buildApp`, after `const registry = ...`:

```ts
  const presence = deps.presence ?? new NoopPresenceService();
```

And change the contacts registration to pass it:

```ts
  app.register(contactsRoutes, { pool: deps.pool, registry, presence });
```

- [ ] **Step 6: Modify `test/helpers/realtime.ts` — pass `registry` + `presence` into `buildApp`, attach after gateway creation**

```ts
  const { RedisSessionRegistry } = await import("../../src/modules/session-registry/redis-session-registry.js");
  const registry = new RedisSessionRegistry();
  const { buildApp } = await import("../../src/app.js");
  const app = await buildApp({ pool, config: testConfig, registry, presence });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const io = createGateway(app.server, { config: testConfig, pub: redis.pub, sub: redis.sub, presence, pool });
  registry.attach(io);
```

Add `registry` to the returned `RealtimeStack` object.

- [ ] **Step 7: Modify `src/server.ts` — wire the full real-time stack**

Replace `server.ts` with:

```ts
import { Pool } from "pg";
import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";
import { runMigrations } from "./db/migrate.js";
import { createRedisClients, closeRedisClients } from "./realtime/redis.js";
import { PresenceService } from "./modules/presence/presence.service.js";
import { RedisSessionRegistry } from "./modules/session-registry/redis-session-registry.js";
import { createGateway } from "./realtime/gateway.js";

async function main() {
  const config = loadConfig();
  const pool = new Pool({ connectionString: config.databaseUrl });
  await runMigrations(pool);

  const redis = await createRedisClients(config.redisUrl);
  const presence = new PresenceService(redis.general, 30);
  const registry = new RedisSessionRegistry();

  const app = await buildApp({ pool, config, registry, presence });
  await app.listen({ port: config.port, host: "0.0.0.0" });

  const io = createGateway(app.server, {
    config,
    pub: redis.pub,
    sub: redis.sub,
    presence,
    pool,
  });
  registry.attach(io);

  // eslint-disable-next-line no-console
  console.log(`PenguinChat API + realtime listening on :${config.port}`);

  const shutdown = async () => {
    io.close();
    await app.close();
    await closeRedisClients(redis);
    await pool.end();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 8: Run the new test and the full suite**

Run: `npm test -- test/contacts-presence.test.ts`
Expected: PASS.

Run: `npm test`
Expected: PASS — all Plan-1 tests (20) + all 2a tests. Existing `test/contacts.test.ts` must still pass because `makeApp` (no `presence` provided) falls back to `NoopPresenceService`.

- [ ] **Step 9: Verify strict build**

Run: `npm run build`
Expected: clean.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat(2a): real presence in /contacts + wire redis stack in server.ts"
```

---

## Task 7: Container boot verification + full suite green

**Files:**
- No source changes. Verification only.

- [ ] **Step 1: Rebuild the container**

```bash
docker compose up -d --build
```

If Docker is down, report BLOCKED (do not start it).

- [ ] **Step 2: Confirm the container self-migrates and boots (now also binds the socket)**

```bash
docker compose logs api --tail 20 | grep -i "listening"
```
Expected: a line containing `PenguinChat API + realtime listening on :3000`.

- [ ] **Step 3: Confirm REST + a socket handshake against the live container**

```bash
# REST still works (self-migrated on boot)
curl -s -X POST localhost:3000/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"username":"livecheck","display_name":"Live","password":"noot123"}' | head -c 120
echo
```
Expected: JSON with `user` and `tokens` (HTTP 201), proving the containerized stack boots and self-migrates with the new Redis wiring.

- [ ] **Step 4: Run the full test suite one more time**

Run: `npm test`
Expected: all tests PASS.

- [ ] **Step 5: Leave infra in a clean running state**

```bash
docker compose up -d postgres redis
```

- [ ] **Step 6: Commit (verification notes, if any docs updated; otherwise skip)**

If no files changed, skip the commit. Otherwise:

```bash
git add -A
git commit -m "chore(2a): verify containerized realtime boot"
```

---

## Self-Review Notes (author — completed)

- **Spec coverage:** Socket.IO gateway + JWT handshake auth (§3/§8) ✔ (Task 3); `@socket.io/redis-adapter` + userId rooms for cross-instance/multi-device fan-out (§9) ✔ (Task 3); `RedisSessionRegistry` replacing the no-op so `friend:request`/`friend:accepted` deliver live (§3/§6) ✔ (Task 2, wired in Task 6); presence `presence:{userId}` key + 30s TTL + heartbeat refresh (§4) ✔ (Task 4); `presence:update` broadcasts on connect/disconnect to friends (§3/§5) ✔ (Task 5); `GET /contacts` real presence (§4) ✔ (Task 6); `REDIS_URL` config + docker-compose (§2) ✔ (Task 1); lazy-`io` holder for the chicken-and-egg (§3) ✔ (Task 2/6).
- **Deferred to 2b (not gaps):** `message:*`, `typing:*`, history endpoint, `message:send` rate limiting — explicitly out of scope per spec §1.
- **Placeholder scan:** none — every step has complete code or an exact command.
- **Type consistency:** `PresenceReader.getMany(userIds): Promise<Map<string, PresenceStatus>>` is the single shape used by `PresenceService`, `NoopPresenceService`, and `listContacts`. `PresenceStatus = "online" | "offline"`. `RedisSessionRegistry.attach(io)` / `notify(userId, event, payload)` match the `SessionRegistry` interface from Plan 1. `createGateway` deps accumulate across tasks (Task 3 adds config/pub/sub; Task 5 adds presence/pool) — the final signature in Task 5/6 is the authoritative one; Task 3's narrower signature is extended, not contradicted. `registerUser` returns `{ id, accessToken, username }` consistently after the Task 5 helper update.
- **Plan-1 regression risk:** the only REST behavior change is `/contacts` presence, which falls back to `NoopPresenceService` (all offline) when `presence` is not injected — so `makeApp`-based existing tests are unaffected. `listContacts` signature change (now takes a `PresenceReader`) is internal; the route is the only caller and is updated in the same task.
