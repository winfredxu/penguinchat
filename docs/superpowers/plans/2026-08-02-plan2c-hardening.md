# PenguinChat Plan 2c - Backend Hardening

**Goal:** Close the high-priority deferred follow-up tickets (FU-11, FU-12, FU-8, FU-1, FU-3/FU-15) plus the trivially-related defense-in-depth items (FU-13, FU-14, FU-7) that touch the same files. No new product features; this hardens what Plan 2b shipped.

**Why now:** Plan 2b made the cross-instance `registry.notify` fan-out load-bearing for *every* messaging event (`message:new`/`delivered`/`read`/`typing`), yet that path has zero multi-instance test coverage (FU-12). FU-11 is a real user-visible presence bug. FU-1 leaves refresh tokens non-rotating for 30 days. FU-3/FU-15 leave CORS ungated before a client ships.

**Tech stack:** unchanged - Node 20, TypeScript strict/ESM, Fastify 4, Socket.IO 4, `pg`, `redis`, Vitest, Docker (Postgres 16 + Redis 7).

## Global Constraints (carry forward from Plan 2b)

- Backend **always runs in Docker**; tests connect to the Dockerized Postgres **and** Redis. Docker is user-managed: NEVER restart the daemon or run `open -a Docker`. If Docker is down, report BLOCKED.
- If any task runs `npm`, first `export npm_config_cache=/tmp/claude-501/-Users-winfredxu-penguinchat/deb5185c-85bd-4194-808f-98b389c6dd23/scratchpad/npm-cache`.
- TypeScript strict, ESM, `.js` import specifiers.
- All 52 existing tests must stay green throughout. No REST/socket behavior changes except where a ticket explicitly demands one (FU-8 adds a 409 on reverse-direction dup; FU-1 changes refresh-token semantics - both are spec-aligned).
- TDD per task: write failing test -> verify fail -> implement -> verify pass -> commit.

## File Structure

```
src/
  db/migrations/002_refresh_tokens.sql        # NEW (FU-1)
  db/migrate.ts                                 # unchanged (reads 002_*.sql automatically)
  modules/
    presence/presence.service.ts               # FU-11: refresh() -> SET EX
    contacts/contacts.repo.ts                   # FU-8: findPendingEitherDirection
    contacts/contacts.service.ts                # FU-8: sendRequest checks both directions
    auth/tokens.ts                              # FU-1/FU-7: jti + type claim + type checks
    auth/auth.repo.ts                           # FU-1: refresh-token repo funcs
    auth/auth.service.ts                        # FU-1: rotation + reuse detection in refresh/register/login
    auth/auth.routes.ts                         # FU-1: unchanged (refresh route passes through)
  realtime/gateway.ts                           # FU-13: sub guard; FU-15: CORS allowlist
  realtime/redis.ts                             # FU-14: Promise.allSettled
  app.ts                                        # FU-3: CORS allowlist
  config.ts                                     # FU-3/FU-15: corsOrigins env
test/
  helpers/
    realtime.ts                                 # FU-12: makeMultiInstanceStack helper
    db.ts                                       # FU-1: resetDb includes refresh_tokens
    app.ts                                      # FU-3: testConfig.corsOrigins
  multi-instance.test.ts                        # FU-12 (NEW)
  presence.service.test.ts                      # FU-11 (extend)
  contacts.test.ts                              # FU-8 (extend)
  auth.refresh-rotation.test.ts                 # FU-1 (NEW)
  cors.test.ts                                  # FU-3 (NEW, unit)
docs/superpowers/plans/2026-08-02-plan2c-hardening.md   # this plan, checked in
```

---

## Task 0: Check in the plan doc

Write this plan to `docs/superpowers/plans/2026-08-02-plan2c-hardening.md` and commit `docs: Plan 2c implementation plan - backend hardening`. (Mirror of the Plan 2b `a6f49b6` commit.)

---

## Task 1: FU-12 - Multi-instance fan-out test (test-only, highest priority)

**Why first:** validates the load-bearing cross-instance path before any source change. Test-only - zero regression risk. If it fails, it surfaces a real bug the rest of 2b depends on.

**Files:** modify `test/helpers/realtime.ts` (add `makeMultiInstanceStack`); create `test/multi-instance.test.ts`.

**Design - `makeMultiInstanceStack`:** spin up TWO independent HTTP+io stacks. Each instance gets its OWN `createRedisClients(testConfig.redisUrl)` (mirrors production - each process has its own pub/sub clients) but they connect to the same Redis, so `@socket.io/redis-adapter` fans emits between them. Each instance: `buildApp` -> `app.listen({port:0})` -> `createGateway(server, {pub,sub,presence,pool})` -> `registerMessagingHandlers(io, {pool, registry})` -> `registry.attach(io)`. Shared single `pool` (same Postgres). Two registries (one per io), two presences (both backed by the same Redis, so presence state is shared).

**Tests (TDD):**
1. `message:new` crosses instances - A on instance 1 sends `message:send` to B; B's socket on instance 2 receives `message:new`. (Validates `registry.notify` -> `io.to(B).emit` -> adapter -> other instance's socket in room B.)
2. `presence:update` crosses instances - A connects on instance 1; B (friend) on instance 2 receives `presence:update {userId:A, status:"online"}`.
3. `typing` / `message:delivered` cross instances (one test each) - confirms the full 2b event surface fans out, not just `message:new`.

**Expected:** PASS with current code (the fan-out should already work - this is a confidence test). If it FAILS, stop and diagnose before Tasks 2-6.

**Commit:** `test(2c): FU-12 multi-instance fan-out tests for presence + messaging`

---

## Task 2: FU-11 - Presence stale race (refresh -> SET EX)

**Bug:** `presence.service.ts` `refresh()` uses `EXPIRE` (no-op on an absent key). Race: disconnect handler's `fetchSockets()` resolves 0, then a new socket connects + `setOnline`, then `clear()` wipes the just-set key. The new socket's next heartbeat calls `refresh` -> `EXPIRE` on absent key -> no-op -> user appears offline to friends until reconnect.

**Fix:** make `refresh()` idempotent-recreate - `SET presence:{userId} online EX {ttl}` - so any racing `clear` is undone by the next heartbeat (~25s). Safe because only genuinely-connected clients emit heartbeats.

```ts
// presence.service.ts
async refresh(userId: string): Promise<void> {
  // SET ... EX recreates the key if a racing disconnect.clear() deleted it
  // (EXPIRE would be a no-op on an absent key and leave presence stale).
  await this.general.set(key(userId), "online", { EX: this.ttlSeconds });
}
```

**Test (extend `presence.service.test.ts`):** after `setOnline` + `clear`, a `refresh` restores the key to `online` (proves self-heal). Also: `refresh` on a never-set key now sets it (behavior change, but safe - only connected clients heartbeat).

**Commit:** `fix(2c): FU-11 presence self-heals racing clear via SET EX in refresh`

---

## Task 3: FU-8 - Bidirectional friend-request duplicate check

**Bug:** `findPendingBetween` + the `friend_requests_pending_uniq` index are both directional `(from_user, to_user)`. If B->A is pending, A->B can still create a second reverse-direction pending request.

**Fix (service-level, matches FU-8 recommendation):** add `findPendingEitherDirection(pool, x, y)` to `contacts.repo.ts` checking both directions; `sendRequest` uses it instead of the directional `findPendingBetween`.

```ts
// contacts.repo.ts
export async function findPendingEitherDirection(
  pool: Pool, x: string, y: string
): Promise<FriendRequestRow | null> {
  const res = await pool.query<FriendRequestRow>(
    `SELECT * FROM friend_requests
     WHERE status = 'pending' AND from_user IN ($1,$2) AND to_user IN ($1,$2)
       AND from_user <> to_user`,
    [x, y]
  );
  return res.rows[0] ?? null;
}
```

`contacts.service.ts` `sendRequest`: replace `findPendingBetween(pool, fromUser, target.id)` with `findPendingEitherDirection(pool, fromUser, target.id)`. Keep `findPendingBetween` (still used elsewhere / not worth removing). The DB index stays directional; the service check prevents the product-level dup. (Concurrent-race dup would still hit FU-10 territory - out of scope.)

**Test (extend `contacts.test.ts`):** B->A pending, then A->B `sendRequest` throws 409 `request_exists`.

**Commit:** `fix(2c): FU-8 friend-request dup check covers both directions`

---

## Task 4: FU-13 + FU-14 - Defense-in-depth batch

Two tiny same-area fixes, batched.

**FU-13** `realtime/gateway.ts`: guard against a `sub`-less access token (defense-in-depth - currently `socket.data.userId` could be `undefined` and the socket joins room `"undefined"`).
```ts
const { sub } = verifyAccess(token, deps.config);
if (!sub) return next(new Error("unauthorized"));
socket.data.userId = sub;
```

**FU-14** `realtime/redis.ts`: `closeRedisClients` uses `Promise.all` - if one `quit()` rejects (client already errored), the other quits aren't awaited, leaking connections.
```ts
export async function closeRedisClients(c: RedisClients): Promise<void> {
  await Promise.allSettled([c.pub.quit(), c.sub.quit(), c.general.quit()]);
}
```

**Tests:** FU-13 - a token signed without `sub` (or with `sub` removed) gets `connect_error` (extend `gateway.auth.test.ts`). FU-14 - unit test that `closeRedisClients` resolves even if one client's `quit` rejects (mock or already-closed client).

**Commit:** `fix(2c): FU-13 gateway sub guard + FU-14 allSettled redis shutdown`

---

## Task 5: FU-3 + FU-15 - Env-driven CORS allowlist

**Bug:** `app.ts` `origin: true` (reflect any Origin); `gateway.ts` `origin: "*"`.

**Fix:** env-driven allowlist. `config.ts` adds `corsOrigins: string[]` from `CORS_ORIGINS` (comma-separated). Empty/unset = allow-all (preserves dev behavior + keeps tests green); set = allowlist. A shared validator helper:

```ts
// src/lib/cors.ts (new, tiny)
export function corsOriginOption(origins: string[]): boolean | ((origin: string, cb: (e: Error | null, ok?: boolean) => void) => void) {
  if (origins.length === 0) return true; // dev default: reflect
  return (origin, cb) => {
    if (!origin || origins.includes(origin)) return cb(null, true);
    return cb(new Error("Not allowed by CORS"), false);
  };
}
```

- `app.ts`: `await app.register(cors, { origin: corsOriginOption(deps.config.corsOrigins) })`.
- `gateway.ts`: `cors: { origin: deps.config.corsOrigins.length ? deps.config.corsOrigins : "*" }`.
- `test/helpers/app.ts` `testConfig`: add `corsOrigins: []`.

**Test (`test/cors.test.ts`, unit):** the validator reflects when `[]`; allows listed origin; rejects unlisted. Plus one integration: with `corsOrigins:["http://localhost:5173"]`, an `app.inject` with `origin: http://evil.com` gets no `access-control-allow-origin` (or a 403-ish CORS rejection), listed origin gets the header.

**Commit:** `fix(2c): FU-3/FU-15 env-driven CORS allowlist for REST + Socket.IO`

---

## Task 6: FU-1 + FU-7 - Refresh-token rotation (jti table) + JWT type claim

**Biggest task.** Chosen strategy: **jti table + reuse detection** (per user decision).

**Migration `002_refresh_tokens.sql`:**
```sql
CREATE TABLE IF NOT EXISTS refresh_tokens (
  jti       text PRIMARY KEY,
  user_id   uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  revoked   boolean NOT NULL DEFAULT false,
  issued_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS refresh_tokens_user_id_idx ON refresh_tokens (user_id);
```
(No `expires_at` - expired JWTs are rejected by `jwt.verify`; rotation/reuse only need jti + revoked. Expired-but-unrevoked rows accumulate - cleanup is a separate ops concern, out of 2c scope.)

**`tokens.ts` (FU-1 + FU-7):** add `jti` (randomUUID) to refresh tokens; add `type: "access"|"refresh"` claim to both; verify functions check the type (FU-7 defense-in-depth - a refresh token can't be used as access and vice versa).
```ts
import { randomUUID } from "node:crypto";

export function issueTokens(userId: string, cfg: TokenConfig) {
  const jti = randomUUID();
  const accessToken = jwt.sign({ sub: userId, type: "access" }, cfg.jwtAccessSecret, { expiresIn: cfg.accessTtl });
  const refreshToken = jwt.sign({ sub: userId, type: "refresh", jti }, cfg.jwtRefreshSecret, { expiresIn: cfg.refreshTtl });
  return { accessToken, refreshToken, jti };
}
export function verifyAccess(token, cfg): { sub: string } {
  const p = jwt.verify(token, cfg.jwtAccessSecret) as any;
  if (p.type !== "access") throw new Error("wrong token type");
  return { sub: p.sub };
}
export function verifyRefresh(token, cfg): { sub: string; jti: string } {
  const p = jwt.verify(token, cfg.jwtRefreshSecret) as any;
  if (p.type !== "refresh") throw new Error("wrong token type");
  return { sub: p.sub, jti: p.jti };
}
```
Note: `issueTokens` now returns `jti` - callers (`register`/`login`/`refresh`) must persist it.

**`auth.repo.ts` (new funcs):**
```ts
insertRefreshToken(pool, { jti, userId }): Promise<void>  // INSERT, ON CONFLICT DO NOTHING
getRefreshToken(pool, jti): Promise<{ revoked: boolean } | null>
revokeRefreshToken(pool, jti): Promise<void>              // UPDATE SET revoked=true
revokeAllRefreshTokens(pool, userId): Promise<void>       // UPDATE SET revoked=true WHERE user_id
```

**`auth.service.ts`:**
- `register` / `login`: after `issueTokens`, `await insertRefreshToken(pool, { jti: tokens.jti, userId: user.id })`. Return `{ accessToken, refreshToken }` (drop jti from the public shape).
- `refresh`:
  1. `verifyRefresh` -> `{ sub, jti }` (catch -> 401 `invalid_token`).
  2. `findById(sub)` -> 401 if missing.
  3. `getRefreshToken(jti)` -> 401 if unknown (not issued by us / cleaned).
  4. **Reuse detection:** if `revoked === true` -> `revokeAllRefreshTokens(sub)` (compromise! revoke every device) -> 401.
  5. **Rotate:** `revokeRefreshToken(jti)`; `issueTokens` -> new pair; `insertRefreshToken(newJti)`.
  6. Return new pair.

**`test/helpers/db.ts`:** `resetDb` must TRUNCATE `refresh_tokens` too (else tests bleed). Verify the truncation list covers it.

**Tests (`test/auth.refresh-rotation.test.ts`):**
1. `refresh` returns a NEW refresh token != old; old jti is now `revoked=true` in DB.
2. Reusing the old (revoked) refresh token -> 401 AND revokes ALL the user's tokens (a second valid refresh token from another "device" also becomes revoked).
3. `register`/`login` persist a non-revoked refresh token row.
4. A refresh token presented as an access token (FU-7) is rejected by `verifyAccess` (gateway/auth plugin) - and vice versa.
5. Tampered/expired refresh -> 401.

**Regression check:** existing `auth.login.test.ts` / `auth.me.test.ts` use freshly issued tokens - they keep passing. The `/auth/refresh` route is unchanged (still `POST /auth/refresh {refreshToken}` -> `{tokens}`); only its semantics deepen.

**Commit:** `feat(2c): FU-1/FU-7 refresh-token rotation (jti table + reuse detection) + JWT type claim`

---

## Task 7: Full suite + strict build + container verify + PR

1. `npm test` -> all green (52 prior + new ~10-12).
2. `npx tsc --noEmit` -> clean.
3. `docker compose up -d --build api`; confirm `listening on :3000`; `curl` history endpoint -> 401 (smoke). `docker compose up -d postgres redis` (leave clean).
4. Update `docs/superpowers/follow-ups.md` - mark FU-1, FU-3, FU-7, FU-8, FU-11, FU-12, FU-13, FU-14, FU-15 as resolved (keep FU-4, FU-5, FU-6, FU-9, FU-10, FU-16 open). Commit `docs: mark FU-1/3/7/8/11/12/13/14/15 resolved`.
5. Push branch `feat/plan2c-hardening`, open PR to `main`.

---

## Self-Review Notes

- **Ordering:** FU-12 first (test-only, validates the path 2b depends on).FU-11/FU-8/FU-13/FU-14 are small isolated fixes. FU-3/FU-15 CORS is config+two wiring points. FU-1/FU-7 is the big one, last, with a migration.
- **Regression risk:** FU-1 changes `issueTokens` return shape - all three callers updated. `resetDb` extended. FU-7 adds a `type` claim - only fresh tokens exist in dev/tests, so the stricter verify is safe. FU-3 CORS defaults to allow-all, so test clients (localhost) keep working. FU-11 changes `refresh` to also create absent keys - safe (only connected clients heartbeat).
- **Authz trace unchanged:** no `socket.data.userId` / `request.userId` semantics change. FU-13 only adds a guard on the existing `sub`.
- **Out of scope (stay open):** FU-4 (unused pool helper), FU-5 (dead re-export), FU-6 (request logging), FU-9 (route :id 400), FU-10 (TOCTOU), FU-16 (handler dep interface) - all Minor, not named in the hardening scope.
