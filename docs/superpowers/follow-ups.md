# PenguinChat — Follow-up Tickets

Tracked items surfaced during the Plan 1 (backend foundation) reviews. None were
merge-blocking; the deploy-blocking migration-on-boot item was fixed before merge
(`fix: run migrations on server boot`). The rest are recorded here.

## From the final whole-branch review

### FU-1 — Refresh-token rotation is cosmetic (Important)
`src/modules/auth/auth.service.ts` `refresh()` issues a new token pair but never
revokes the presented refresh token — it stays valid for its full 30-day TTL. The
design spec §8 says refresh tokens are "rotated"; real rotation requires detecting
and rejecting reuse of a rotated-out token. Needs a persistence layer (a
`refresh_tokens` table with a `jti`, or a per-user `token_version`). Natural fit to
fold into Plan 2 (or a dedicated auth-hardening task) since it also unlocks
"log out everywhere" / "revoke on password change". *Note: Plan 1's Task 4
deliberately specified the current behavior; this is a spec-intent upgrade, not a
regression.*

### FU-3 — CORS `origin: true` is ungated (Important)
`src/app.ts` registers `@fastify/cors` with `origin: true`, reflecting any Origin.
Not an immediate vector (auth is Bearer-token, not cookie-based), but should become
an env-driven allowlist before the Plan 3 client ships to production.

### FU-4 — `db/pool.ts` `query()` helper is unused (Minor)
The plan positioned `db/pool.ts` as the single query chokepoint, but every repo
calls `pool.query(...)` directly. Either route repos through the helper (gives one
interception point for logging/tracing/metrics — useful for Plan 2 history paging)
or delete the dead helper.

### FU-5 — Dead re-export in `contacts.service.ts` (Minor)
`export { findById }` is re-exported from the contacts service but never imported.
Remove, or wire up the intended call site (e.g. enriching the accept response with
the new friend's details).

### FU-6 — No production request logging (Minor)
`Fastify({ logger: false })` disables structured logging entirely; only
startup/fatal errors are logged. Add request logging before real traffic —
debugging Plan 2's socket/session issues without an HTTP trail will be painful.

### FU-7 — JWT tokens lack a `type` claim (Minor)
`issueTokens` signs `{ sub }` for both access and refresh; only the differing
secrets prevent cross-use. Add a `type: "access" | "refresh"` claim and check it in
each verify function as defense-in-depth against a misconfigured (shared) secret.

## From per-task reviews

### FU-8 — `sendRequest` directional duplicate gap (Important-ish, product bug)
`contacts.repo.ts` `findPendingBetween` and the partial unique index
`friend_requests_pending_uniq` are both directional `(from_user, to_user)`. If B→A
is pending, A→B can still create a second reverse-direction pending request. Fix:
check/normalize both directions (or add a second index / a normalized pair column).
Not a security hole — data/UX duplication only.

### FU-9 — Route `:id` params not validated → 500 instead of 400 (Minor)
`contacts.routes.ts` accept/decline cast `req.params` without schema validation; a
malformed non-UUID `:id` throws in Postgres's uuid parser and falls through to the
generic 500 handler. Add a uuid schema (or a param `safeParse`) to return a clean
400.

### FU-10 — Check-then-insert TOCTOU (Minor, low risk)
`register()` (username has a DB UNIQUE backstop → worst case a 500 instead of 409
under concurrent duplicate signups) and the migration runner (sequential-use-only;
concurrent replicas would hit a duplicate-key error rather than silently no-op).
Acceptable for now; revisit if migrations ever run from multiple replicas at boot
(now that the server self-migrates, FU-10's migration half is worth a glance before
horizontal scaling).

## From the Plan 2a final review

### FU-11 — Disconnect/clear race can leave presence stale (Important-ish)
`src/modules/presence/presence.handlers.ts` disconnect handler: between
`io.in(userId).fetchSockets()` resolving (0 sockets) and `presence.clear(userId)`
running, a new socket for the same user can connect and `setOnline` the key — then
`clear` deletes the just-set key. The user is connected but appears offline to
friends. Heartbeat does NOT self-heal because `refresh()` uses `EXPIRE` (no-op on an
absent key) rather than `SET ... EX`. Fix: make `refresh()` idempotent-recreate —
`SET presence:{userId} online EX {ttl}` — so any racing clear is undone by the next
heartbeat (~25s) even without a reconnect. Safe because only connected clients emit
heartbeats, so a ghost socket can't resurrect presence.

### FU-12 — Multi-instance fan-out untested (Important for prod)
`@socket.io/redis-adapter` is wired and `io.in(userId).fetchSockets()` is
cluster-aware, but all Plan 2a tests use a single `io` instance. Add a two-instance
test (two `io` servers sharing one Redis adapter, a socket on each, assert a
`presence:update` / `notify` emitted on instance A reaches a socket on instance B)
before this is load-bearing in production.

### FU-13 — `verifyAccess` return is an unchecked cast (Minor)
`src/realtime/gateway.ts`: `const { sub } = verifyAccess(...)` — if a validly-signed
access token ever lacks `sub`, `socket.data.userId` is `undefined` and the socket
joins a room literally named `"undefined"`. Not exploitable without the secret, but
add `if (!sub) return next(new Error("unauthorized"))` as defense-in-depth.

### FU-14 — `closeRedisClients` uses `Promise.all` (Minor)
`src/realtime/redis.ts`: if one `quit()` rejects (client already in error state),
`Promise.all` rejects and the other two quits aren't awaited, leaking connections.
Use `Promise.allSettled`.

### FU-15 — Socket.IO CORS `origin: "*"` (Minor)
`src/realtime/gateway.ts`: acceptable for 2a (JWT-in-handshake, not cookie-based, so
`*` widens no attack surface), but make it env-driven before the Plan 3 client ships
to production. Ties to FU-6 / prod-readiness.

### FU-16 — `PresenceHandlerDeps` couples to concrete `PresenceService` (Minor)
`src/modules/presence/presence.handlers.ts` types the dep as the concrete class, not
an interface. Fine for 2a (the handler needs write methods); if 2b wants to swap a
presence impl in tests, introduce a `PresenceWriter` interface.
