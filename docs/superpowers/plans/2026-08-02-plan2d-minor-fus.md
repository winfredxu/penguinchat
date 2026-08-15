# PenguinChat Plan 2d - Minor Follow-up Cleanups

Closes the remaining Minor follow-up tickets (FU-4, FU-5, FU-6, FU-9). These are
small, isolated hardening/cleanup items that did not fit Plan 2c's high-priority
scope. FU-10 (TOCTOU, deemed acceptable) and FU-16 (handler dep interface, no
current need) remain open.

Stacked on Plan 2c (`feat/plan2c-hardening`).

## Tasks

### Task 1: FU-4 - Delete unused `db/pool.ts` query helper
`src/db/pool.ts` exports a `query()` wrapper positioned as a single query chokepoint,
but every repo calls `pool.query(...)` directly and nothing imports the file. Delete
the file. (If logging/tracing is ever wanted, add it then.) No test - pure dead-code
removal; the full suite staying green is the check.

### Task 2: FU-5 - Remove dead `findById` re-export in `contacts.service.ts`
`contacts.service.ts` imports `findById` from `auth.repo` solely to re-export it; the
re-export is imported nowhere. Remove the import and the re-export.

### Task 3: FU-9 - Validate `:id` uuid in contacts accept/decline -> 400 not 500
`contacts.routes.ts` casts `req.params` without validation; a non-uuid `:id` throws in
Postgres's uuid parser and surfaces as a 500. Add a `z.string().uuid()` param check
(consistent with the existing zod usage) returning 400 `invalid_payload`.
Test: `POST /friend-requests/not-a-uuid/accept` -> 400.

### Task 4: FU-6 - Enable structured request logging
`app.ts` uses `Fastify({ logger: false })` - no HTTP trail. Add a `logLevel` config
field (env `LOG_LEVEL`, default `info`; `silent` in tests) and enable Fastify's pino
logger. Test: a request emits a structured log line (assert via a custom destination
or that `app.log` is a real logger).

### Task 5: Full suite + build + PR
