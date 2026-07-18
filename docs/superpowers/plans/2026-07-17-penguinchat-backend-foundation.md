# PenguinChat Backend Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the stateless backend foundation for PenguinChat v1 — database schema, argon2/JWT authentication, and the friends/contacts REST API — as a Dockerized Fastify service, fully test-covered, ready for the real-time slice to bolt on.

**Architecture:** Fastify HTTP server with domain modules (`auth`, `contacts`) backed by PostgreSQL via `pg`. Tests exercise routes in-process with `app.inject()` against a Dockerized Postgres. Real-time concerns (Socket.IO, Redis, presence) are **out of scope** for this plan but their seams are defined: `session-registry` is declared as an interface with a no-op implementation so Plan 2 can drop in the Redis-backed version without touching `contacts`/`messaging`.

**Tech Stack:** Node.js 20+, TypeScript, Fastify 4, `pg` (node-postgres), `argon2`, `jsonwebtoken`, `zod` (payload validation), Vitest (test runner), Docker + docker-compose (Postgres 16, Redis 7).

## Global Constraints

- Backend **always runs in Docker** — never on the local machine (project convention). Postgres and Redis run via `docker-compose`; the app image is built from a `Dockerfile`. Tests connect to the Dockerized Postgres.
- Passwords hashed with **argon2id**; password hashes are **never logged or returned** in any response.
- JWT **access tokens** short-lived (~15 min); **refresh tokens** long-lived and **rotated** on every refresh.
- All authorization is **server-side**: a user may only act on their own resources; a user may only message existing friends (enforced in later plans).
- **Input validation at every boundary** — every REST payload is schema-validated (zod) before touching a domain service.
- Friendships stored **one row per pair**, `user_a < user_b` by uuid, to avoid duplicate/asymmetric rows.
- `conversation` id is the **deterministic UUIDv5** of the sorted user pair (defined here, consumed by messaging in Plan 2).
- Deterministic UUIDv5 namespace constant (fixed, never regenerate): `6f9619ff-8b86-1011-b42d-00c04fc964ff`. (Corrected during Task 2 — the original `...d011...` had an out-of-range version nibble and was rejected by `uuidv5`.)
- Rate-limit auth endpoints (defined as a shared limiter; tuned in a later hardening pass).

---

## File Structure

```
penguinchat/
  package.json
  tsconfig.json
  vitest.config.ts
  Dockerfile
  docker-compose.yml
  .env.example
  .dockerignore
  src/
    config.ts                 # env parsing, typed config object
    app.ts                    # buildApp(): assembles Fastify + plugins + routes (no listen)
    server.ts                 # reads config, calls buildApp().listen() — the container entrypoint
    db/
      pool.ts                 # pg Pool singleton + query helper
      migrate.ts              # migration runner (applies src/db/migrations/*.sql in order)
      migrations/
        001_init.sql          # users, friendships, friend_requests, messages
    lib/
      ids.ts                  # conversationId(a, b) — deterministic UUIDv5 of sorted pair
      errors.ts               # AppError + typed error helpers
    plugins/
      auth.ts                 # Fastify plugin: verifies access token, sets request.userId
    modules/
      auth/
        password.ts           # hashPassword / verifyPassword (argon2id)
        tokens.ts             # issueTokens / verifyAccess / verifyRefresh (JWT)
        auth.repo.ts          # user row CRUD
        auth.service.ts       # register / login / refresh / getMe / updateMe
        auth.routes.ts        # POST /auth/*, GET+PATCH /me
        auth.schema.ts        # zod schemas for auth payloads
      contacts/
        contacts.repo.ts      # friendships + friend_requests CRUD
        contacts.service.ts   # sendRequest / listRequests / accept / decline / listContacts
        contacts.routes.ts    # /contacts, /friend-requests
        contacts.schema.ts    # zod schemas for contacts payloads
      session-registry/
        session-registry.ts   # SessionRegistry interface + NoopSessionRegistry (Plan 2 replaces impl)
  test/
    helpers/
      db.ts                   # resetDb(): truncate all tables between tests
      app.ts                  # makeApp(): buildApp wired to test config
    health.test.ts
    db.migrate.test.ts
    auth.register.test.ts
    auth.login.test.ts
    auth.me.test.ts
    contacts.test.ts
```

**Responsibility boundaries:** each module owns its routes + service + repo + schema. `session-registry` is the only cross-module dependency for notifications, and it's an interface — `contacts` calls it but doesn't know its implementation. `db/pool.ts` is the single place that owns the connection.

---

## Roadmap (context — later plans, NOT this plan)

- **Plan 2 — Real-time messaging + presence:** Socket.IO gateway with JWT handshake auth, `messaging` module (persist/route/receipts/history paging), `presence` module, and the **Redis-backed `SessionRegistry`** replacing the no-op from this plan. Adds `GET /conversations/:userId/messages`.
- **Plan 3 — Electron/React client:** frameless three-column QQ-style UI wired to the Plan 1 REST API and Plan 2 socket events; `keytar` refresh-token storage.

Everything below is **Plan 1 only.**

---

## Task 1: Project scaffold, Docker, config, health check

**Files:**
- Create: `package.json`, `tsconfig.json`, `vitest.config.ts`, `.dockerignore`, `.env.example`, `docker-compose.yml`, `Dockerfile`
- Create: `src/config.ts`, `src/app.ts`, `src/server.ts`
- Create: `test/helpers/app.ts`, `test/health.test.ts`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `buildApp(deps: AppDeps): FastifyInstance` from `src/app.ts` — assembles the server without calling `listen`. `AppDeps = { pool: Pool; registry: SessionRegistry }` (registry type imported in Task 6; for now type it as `unknown` placeholder is NOT allowed — instead Task 1 defines `AppDeps` with only `pool: Pool`, and Task 6 extends it). To avoid churn, **Task 1 defines `AppDeps` as `{ pool: Pool }`**; Task 6 adds `registry`.
  - `loadConfig(): Config` from `src/config.ts` — `Config = { port: number; databaseUrl: string; jwtAccessSecret: string; jwtRefreshSecret: string; accessTtl: string; refreshTtl: string }`.

- [ ] **Step 1: Create `package.json`**

```json
{
  "name": "penguinchat-backend",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "engines": { "node": ">=20" },
  "scripts": {
    "build": "tsc -p tsconfig.json",
    "start": "node dist/server.js",
    "dev": "tsx watch src/server.ts",
    "migrate": "tsx src/db/migrate.ts",
    "test": "vitest run",
    "test:watch": "vitest"
  },
  "dependencies": {
    "@fastify/cors": "^9.0.1",
    "@fastify/rate-limit": "^9.1.0",
    "argon2": "^0.41.1",
    "fastify": "^4.28.1",
    "jsonwebtoken": "^9.0.2",
    "pg": "^8.12.0",
    "uuid": "^10.0.0",
    "zod": "^3.23.8"
  },
  "devDependencies": {
    "@types/jsonwebtoken": "^9.0.6",
    "@types/node": "^20.14.0",
    "@types/pg": "^8.11.6",
    "tsx": "^4.16.0",
    "typescript": "^5.5.0",
    "vitest": "^2.0.0"
  }
}
```

- [ ] **Step 2: Create `tsconfig.json`**

```json
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ES2022",
    "moduleResolution": "bundler",
    "outDir": "dist",
    "rootDir": "src",
    "strict": true,
    "esModuleInterop": true,
    "skipLibCheck": true,
    "resolveJsonModule": true,
    "declaration": false,
    "sourceMap": true
  },
  "include": ["src"]
}
```

- [ ] **Step 3: Create `vitest.config.ts`**

```ts
import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
    fileParallelism: false, // tests share one Postgres; run files serially
    hookTimeout: 30000,
    testTimeout: 20000,
  },
});
```

- [ ] **Step 4: Create `.dockerignore`**

```
node_modules
dist
.git
*.md
test
```

- [ ] **Step 5: Create `.env.example`**

```
PORT=3000
DATABASE_URL=postgres://penguin:penguin@localhost:5432/penguinchat
JWT_ACCESS_SECRET=dev-access-secret-change-me
JWT_REFRESH_SECRET=dev-refresh-secret-change-me
ACCESS_TTL=15m
REFRESH_TTL=30d
```

- [ ] **Step 6: Create `docker-compose.yml`**

```yaml
services:
  postgres:
    image: postgres:16
    environment:
      POSTGRES_USER: penguin
      POSTGRES_PASSWORD: penguin
      POSTGRES_DB: penguinchat
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U penguin -d penguinchat"]
      interval: 3s
      timeout: 3s
      retries: 10
    volumes:
      - pgdata:/var/lib/postgresql/data

  redis:
    image: redis:7
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 3s
      timeout: 3s
      retries: 10

  api:
    build: .
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    environment:
      PORT: 3000
      DATABASE_URL: postgres://penguin:penguin@postgres:5432/penguinchat
      JWT_ACCESS_SECRET: dev-access-secret-change-me
      JWT_REFRESH_SECRET: dev-refresh-secret-change-me
      ACCESS_TTL: 15m
      REFRESH_TTL: 30d
    ports:
      - "3000:3000"

volumes:
  pgdata:
```

- [ ] **Step 7: Create `Dockerfile`**

```dockerfile
FROM node:20-slim AS build
WORKDIR /app
COPY package.json ./
RUN npm install
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

FROM node:20-slim
WORKDIR /app
ENV NODE_ENV=production
COPY package.json ./
RUN npm install --omit=dev
COPY --from=build /app/dist ./dist
COPY src/db/migrations ./dist/db/migrations
CMD ["node", "dist/server.js"]
```

- [ ] **Step 8: Create `src/config.ts`**

```ts
export interface Config {
  port: number;
  databaseUrl: string;
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
    jwtAccessSecret: required("JWT_ACCESS_SECRET"),
    jwtRefreshSecret: required("JWT_REFRESH_SECRET"),
    accessTtl: process.env.ACCESS_TTL ?? "15m",
    refreshTtl: process.env.REFRESH_TTL ?? "30d",
  };
}
```

- [ ] **Step 9: Create `src/app.ts`**

```ts
import Fastify, { FastifyInstance } from "fastify";
import type { Pool } from "pg";

export interface AppDeps {
  pool: Pool;
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({ logger: false });

  app.get("/health", async () => ({ status: "ok" }));

  // Routes are registered by later tasks:
  // app.register(authRoutes, { deps });
  // app.register(contactsRoutes, { deps });

  return app;
}
```

- [ ] **Step 10: Create `src/server.ts`**

```ts
import { Pool } from "pg";
import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";

async function main() {
  const config = loadConfig();
  const pool = new Pool({ connectionString: config.databaseUrl });
  const app = buildApp({ pool });
  await app.listen({ port: config.port, host: "0.0.0.0" });
  // eslint-disable-next-line no-console
  console.log(`PenguinChat API listening on :${config.port}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
```

- [ ] **Step 11: Create `test/helpers/app.ts`**

```ts
import { Pool } from "pg";
import { buildApp } from "../../src/app.js";

const TEST_DB_URL =
  process.env.DATABASE_URL ??
  "postgres://penguin:penguin@localhost:5432/penguinchat";

export function makePool(): Pool {
  return new Pool({ connectionString: TEST_DB_URL });
}

export function makeApp(pool: Pool) {
  return buildApp({ pool });
}
```

- [ ] **Step 12: Write the failing test — `test/health.test.ts`**

```ts
import { afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";

const pool = makePool();
const app = makeApp(pool);

afterAll(async () => {
  await app.close();
  await pool.end();
});

test("GET /health returns ok", async () => {
  const res = await app.inject({ method: "GET", url: "/health" });
  expect(res.statusCode).toBe(200);
  expect(res.json()).toEqual({ status: "ok" });
});
```

- [ ] **Step 13: Start infra and run the test**

```bash
docker compose up -d postgres redis
npm install
npm test -- test/health.test.ts
```
Expected: PASS (1 test). If Docker is down, ask the user to start Docker Desktop — do not start it yourself.

- [ ] **Step 14: Commit**

```bash
git init -q 2>/dev/null; git add -A
git commit -m "feat: scaffold Fastify backend with Docker, config, health check"
```

---

## Task 2: Database pool, migration runner, initial schema

**Files:**
- Create: `src/db/pool.ts`, `src/db/migrate.ts`, `src/db/migrations/001_init.sql`, `src/lib/ids.ts`
- Create: `test/helpers/db.ts`, `test/db.migrate.test.ts`

**Interfaces:**
- Consumes: `Pool` from `pg` (Task 1).
- Produces:
  - `runMigrations(pool: Pool): Promise<void>` from `src/db/migrate.ts` — idempotent; applies each `NNN_*.sql` once, tracked in a `schema_migrations` table.
  - `conversationId(a: string, b: string): string` from `src/lib/ids.ts` — UUIDv5 of the sorted `[a,b]` pair; order-independent.
  - `resetDb(pool: Pool): Promise<void>` from `test/helpers/db.ts` — truncates all data tables.

- [ ] **Step 1: Create `src/lib/ids.ts`**

```ts
import { v5 as uuidv5 } from "uuid";

// Fixed namespace — never regenerate (see Global Constraints).
const NAMESPACE = "6f9619ff-8b86-1011-b42d-00c04fc964ff";

/** Deterministic conversation id for a user pair, independent of argument order. */
export function conversationId(a: string, b: string): string {
  const [lo, hi] = a < b ? [a, b] : [b, a];
  return uuidv5(`${lo}:${hi}`, NAMESPACE);
}
```

- [ ] **Step 2: Write the failing test for `conversationId` — append to a new `test/db.migrate.test.ts` top section**

```ts
import { beforeAll, afterAll, expect, test } from "vitest";
import { conversationId } from "../src/lib/ids.js";
import { runMigrations } from "../src/db/migrate.js";
import { makePool } from "./helpers/app.js";

test("conversationId is order-independent and stable", () => {
  const a = "11111111-1111-1111-1111-111111111111";
  const b = "22222222-2222-2222-2222-222222222222";
  expect(conversationId(a, b)).toBe(conversationId(b, a));
  expect(conversationId(a, b)).toMatch(/^[0-9a-f-]{36}$/);
});
```

- [ ] **Step 3: Run it to verify it fails**

Run: `npm test -- test/db.migrate.test.ts`
Expected: FAIL — `runMigrations` / migrate module not found (import error).

- [ ] **Step 4: Create `src/db/pool.ts`**

```ts
import { Pool, QueryResult, QueryResultRow } from "pg";

export type { Pool };

export async function query<T extends QueryResultRow = QueryResultRow>(
  pool: Pool,
  text: string,
  params: unknown[] = []
): Promise<QueryResult<T>> {
  return pool.query<T>(text, params as never[]);
}
```

- [ ] **Step 5: Create `src/db/migrations/001_init.sql`**

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS users (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username      text UNIQUE NOT NULL,
  display_name  text NOT NULL,
  password_hash text NOT NULL,
  avatar_url    text,
  signature     text,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS friendships (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_a     uuid NOT NULL REFERENCES users(id),
  user_b     uuid NOT NULL REFERENCES users(id),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_a, user_b),
  CHECK (user_a < user_b)
);

CREATE TABLE IF NOT EXISTS friend_requests (
  id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  from_user  uuid NOT NULL REFERENCES users(id),
  to_user    uuid NOT NULL REFERENCES users(id),
  message    text,
  status     text NOT NULL CHECK (status IN ('pending','accepted','declined')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS friend_requests_pending_uniq
  ON friend_requests (from_user, to_user) WHERE status = 'pending';

CREATE TABLE IF NOT EXISTS messages (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation uuid NOT NULL,
  sender_id    uuid NOT NULL REFERENCES users(id),
  recipient_id uuid NOT NULL REFERENCES users(id),
  body         text NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  read_at      timestamptz
);

CREATE INDEX IF NOT EXISTS messages_conversation_created_idx
  ON messages (conversation, created_at);
```

- [ ] **Step 6: Create `src/db/migrate.ts`**

```ts
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Pool } from "pg";

const here = dirname(fileURLToPath(import.meta.url));
const migrationsDir = join(here, "migrations");

export async function runMigrations(pool: Pool): Promise<void> {
  await pool.query(
    `CREATE TABLE IF NOT EXISTS schema_migrations (
       name text PRIMARY KEY,
       applied_at timestamptz NOT NULL DEFAULT now()
     )`
  );
  const files = readdirSync(migrationsDir).filter((f) => f.endsWith(".sql")).sort();
  for (const file of files) {
    const done = await pool.query("SELECT 1 FROM schema_migrations WHERE name = $1", [file]);
    if (done.rowCount) continue;
    const sql = readFileSync(join(migrationsDir, file), "utf8");
    const client = await pool.connect();
    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query("INSERT INTO schema_migrations (name) VALUES ($1)", [file]);
      await client.query("COMMIT");
    } catch (e) {
      await client.query("ROLLBACK");
      throw e;
    } finally {
      client.release();
    }
  }
}

// Allow `npm run migrate` to run this directly.
if (process.argv[1] && process.argv[1].endsWith("migrate.ts")) {
  const { Pool } = await import("pg");
  const pool = new Pool({ connectionString: process.env.DATABASE_URL });
  await runMigrations(pool);
  await pool.end();
  console.log("migrations applied");
}
```

- [ ] **Step 7: Create `test/helpers/db.ts`**

```ts
import type { Pool } from "pg";

export async function resetDb(pool: Pool): Promise<void> {
  await pool.query(
    "TRUNCATE messages, friend_requests, friendships, users RESTART IDENTITY CASCADE"
  );
}
```

- [ ] **Step 8: Extend `test/db.migrate.test.ts` with the migration test**

```ts
const pool = makePool();

beforeAll(async () => {
  await runMigrations(pool);
});

afterAll(async () => {
  await pool.end();
});

test("migration creates expected tables", async () => {
  const res = await pool.query(
    `SELECT table_name FROM information_schema.tables
     WHERE table_schema = 'public' ORDER BY table_name`
  );
  const names = res.rows.map((r) => r.table_name);
  expect(names).toEqual(
    expect.arrayContaining([
      "friend_requests",
      "friendships",
      "messages",
      "schema_migrations",
      "users",
    ])
  );
});

test("runMigrations is idempotent", async () => {
  await runMigrations(pool); // second run should be a no-op
  const res = await pool.query("SELECT count(*) FROM schema_migrations");
  expect(Number(res.rows[0].count)).toBeGreaterThanOrEqual(1);
});
```

- [ ] **Step 9: Run the tests**

Run: `npm test -- test/db.migrate.test.ts`
Expected: PASS (3 tests).

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "feat: add db pool, migration runner, initial schema, conversation ids"
```

---

## Task 3: Password hashing + JWT + register

**Files:**
- Create: `src/lib/errors.ts`, `src/modules/auth/password.ts`, `src/modules/auth/tokens.ts`, `src/modules/auth/auth.schema.ts`, `src/modules/auth/auth.repo.ts`, `src/modules/auth/auth.service.ts`, `src/modules/auth/auth.routes.ts`
- Modify: `src/app.ts` (register auth routes)
- Create: `test/auth.register.test.ts`

**Interfaces:**
- Consumes: `Pool` (Task 1), `query` (Task 2), `Config` (Task 1).
- Produces:
  - `hashPassword(pw: string): Promise<string>`, `verifyPassword(hash: string, pw: string): Promise<boolean>` (argon2id).
  - `issueTokens(userId: string, cfg: TokenConfig): { accessToken: string; refreshToken: string }`, `verifyAccess(token, cfg): { sub: string }`, `verifyRefresh(token, cfg): { sub: string }`. `TokenConfig = { jwtAccessSecret; jwtRefreshSecret; accessTtl; refreshTtl }`.
  - `PublicUser = { id; username; display_name; avatar_url: string|null; signature: string|null; created_at: string }` — the **only** user shape returned by any route (no `password_hash`).
  - `authRoutes` Fastify plugin registered at root; provides `POST /auth/register`.
  - `AppError(status: number, code: string, message: string)`.

- [ ] **Step 1: Create `src/lib/errors.ts`**

```ts
export class AppError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string
  ) {
    super(message);
  }
}
```

- [ ] **Step 2: Create `src/modules/auth/password.ts`**

```ts
import argon2 from "argon2";

export function hashPassword(pw: string): Promise<string> {
  return argon2.hash(pw, { type: argon2.argon2id });
}

export function verifyPassword(hash: string, pw: string): Promise<boolean> {
  return argon2.verify(hash, pw);
}
```

- [ ] **Step 3: Create `src/modules/auth/tokens.ts`**

```ts
import jwt from "jsonwebtoken";

export interface TokenConfig {
  jwtAccessSecret: string;
  jwtRefreshSecret: string;
  accessTtl: string;
  refreshTtl: string;
}

export function issueTokens(userId: string, cfg: TokenConfig) {
  const accessToken = jwt.sign({ sub: userId }, cfg.jwtAccessSecret, {
    expiresIn: cfg.accessTtl,
  });
  const refreshToken = jwt.sign({ sub: userId }, cfg.jwtRefreshSecret, {
    expiresIn: cfg.refreshTtl,
  });
  return { accessToken, refreshToken };
}

export function verifyAccess(token: string, cfg: TokenConfig): { sub: string } {
  return jwt.verify(token, cfg.jwtAccessSecret) as { sub: string };
}

export function verifyRefresh(token: string, cfg: TokenConfig): { sub: string } {
  return jwt.verify(token, cfg.jwtRefreshSecret) as { sub: string };
}
```

- [ ] **Step 4: Create `src/modules/auth/auth.schema.ts`**

```ts
import { z } from "zod";

export const registerSchema = z.object({
  username: z.string().min(3).max(32).regex(/^[a-zA-Z0-9_]+$/),
  display_name: z.string().min(1).max(48),
  password: z.string().min(6).max(128),
});

export const loginSchema = z.object({
  username: z.string().min(1),
  password: z.string().min(1),
});

export const refreshSchema = z.object({
  refreshToken: z.string().min(1),
});

export const updateMeSchema = z.object({
  display_name: z.string().min(1).max(48).optional(),
  signature: z.string().max(140).optional(),
  avatar_url: z.string().url().max(500).optional(),
});
```

- [ ] **Step 5: Create `src/modules/auth/auth.repo.ts`**

```ts
import type { Pool } from "pg";

export interface UserRow {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  avatar_url: string | null;
  signature: string | null;
  created_at: string;
}

export interface PublicUser {
  id: string;
  username: string;
  display_name: string;
  avatar_url: string | null;
  signature: string | null;
  created_at: string;
}

export function toPublic(u: UserRow): PublicUser {
  const { password_hash, ...rest } = u;
  void password_hash;
  return rest;
}

export async function insertUser(
  pool: Pool,
  input: { username: string; display_name: string; password_hash: string }
): Promise<UserRow> {
  const res = await pool.query<UserRow>(
    `INSERT INTO users (username, display_name, password_hash)
     VALUES ($1, $2, $3) RETURNING *`,
    [input.username, input.display_name, input.password_hash]
  );
  return res.rows[0];
}

export async function findByUsername(pool: Pool, username: string): Promise<UserRow | null> {
  const res = await pool.query<UserRow>("SELECT * FROM users WHERE username = $1", [username]);
  return res.rows[0] ?? null;
}

export async function findById(pool: Pool, id: string): Promise<UserRow | null> {
  const res = await pool.query<UserRow>("SELECT * FROM users WHERE id = $1", [id]);
  return res.rows[0] ?? null;
}

export async function updateUser(
  pool: Pool,
  id: string,
  fields: { display_name?: string; signature?: string; avatar_url?: string }
): Promise<UserRow> {
  const sets: string[] = [];
  const vals: unknown[] = [];
  let i = 1;
  for (const [k, v] of Object.entries(fields)) {
    if (v !== undefined) {
      sets.push(`${k} = $${i++}`);
      vals.push(v);
    }
  }
  if (sets.length === 0) {
    const cur = await findById(pool, id);
    return cur as UserRow;
  }
  vals.push(id);
  const res = await pool.query<UserRow>(
    `UPDATE users SET ${sets.join(", ")} WHERE id = $${i} RETURNING *`,
    vals
  );
  return res.rows[0];
}
```

- [ ] **Step 6: Create `src/modules/auth/auth.service.ts`**

```ts
import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { hashPassword, verifyPassword } from "./password.js";
import { issueTokens, verifyRefresh } from "./tokens.js";
import {
  findById,
  findByUsername,
  insertUser,
  toPublic,
  updateUser,
  type PublicUser,
} from "./auth.repo.js";

export interface AuthResult {
  user: PublicUser;
  tokens: { accessToken: string; refreshToken: string };
}

export async function register(
  pool: Pool,
  cfg: Config,
  input: { username: string; display_name: string; password: string }
): Promise<AuthResult> {
  const existing = await findByUsername(pool, input.username);
  if (existing) throw new AppError(409, "username_taken", "Username already taken");
  const password_hash = await hashPassword(input.password);
  const user = await insertUser(pool, {
    username: input.username,
    display_name: input.display_name,
    password_hash,
  });
  return { user: toPublic(user), tokens: issueTokens(user.id, cfg) };
}

export async function login(
  pool: Pool,
  cfg: Config,
  input: { username: string; password: string }
): Promise<AuthResult> {
  const user = await findByUsername(pool, input.username);
  if (!user) throw new AppError(401, "invalid_credentials", "Invalid username or password");
  const ok = await verifyPassword(user.password_hash, input.password);
  if (!ok) throw new AppError(401, "invalid_credentials", "Invalid username or password");
  return { user: toPublic(user), tokens: issueTokens(user.id, cfg) };
}

export async function refresh(
  pool: Pool,
  cfg: Config,
  refreshToken: string
): Promise<{ tokens: { accessToken: string; refreshToken: string } }> {
  let sub: string;
  try {
    sub = verifyRefresh(refreshToken, cfg).sub;
  } catch {
    throw new AppError(401, "invalid_token", "Invalid refresh token");
  }
  const user = await findById(pool, sub);
  if (!user) throw new AppError(401, "invalid_token", "Invalid refresh token");
  // Rotation: issue a brand-new pair every refresh.
  return { tokens: issueTokens(user.id, cfg) };
}

export async function getMe(pool: Pool, userId: string): Promise<PublicUser> {
  const user = await findById(pool, userId);
  if (!user) throw new AppError(404, "not_found", "User not found");
  return toPublic(user);
}

export async function updateMe(
  pool: Pool,
  userId: string,
  fields: { display_name?: string; signature?: string; avatar_url?: string }
): Promise<PublicUser> {
  const user = await updateUser(pool, userId, fields);
  return toPublic(user);
}
```

- [ ] **Step 7: Create `src/modules/auth/auth.routes.ts`**

```ts
import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { registerSchema } from "./auth.schema.js";
import { register } from "./auth.service.js";

interface Opts {
  pool: Pool;
  config: Config;
}

export async function authRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, config } = opts;

  app.post("/auth/register", async (req, reply) => {
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    const result = await register(pool, config, parsed.data);
    reply.code(201);
    return result;
  });
}
```

- [ ] **Step 8: Modify `src/app.ts` — wire config + auth routes + error handler**

Replace the file with:

```ts
import Fastify, { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "./config.js";
import { AppError } from "./lib/errors.js";
import { authRoutes } from "./modules/auth/auth.routes.js";

export interface AppDeps {
  pool: Pool;
  config: Config;
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({ logger: false });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof AppError) {
      reply.code(err.status).send({ error: err.code, message: err.message });
      return;
    }
    reply.code(500).send({ error: "internal", message: "Internal server error" });
  });

  app.get("/health", async () => ({ status: "ok" }));
  app.register(authRoutes, { pool: deps.pool, config: deps.config });

  return app;
}
```

- [ ] **Step 9: Modify `src/server.ts` — pass config into `buildApp`**

Change the `buildApp` call to:

```ts
  const app = buildApp({ pool, config });
```

- [ ] **Step 10: Modify `test/helpers/app.ts` — supply a test config**

Replace `makeApp` with:

```ts
import type { Config } from "../../src/config.js";

export const testConfig: Config = {
  port: 0,
  databaseUrl: TEST_DB_URL,
  jwtAccessSecret: "test-access",
  jwtRefreshSecret: "test-refresh",
  accessTtl: "15m",
  refreshTtl: "30d",
};

export function makeApp(pool: Pool) {
  return buildApp({ pool, config: testConfig });
}
```

- [ ] **Step 11: Write the failing test — `test/auth.register.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => {
  await runMigrations(pool);
});
beforeEach(async () => {
  await resetDb(pool);
});
afterAll(async () => {
  await app.close();
  await pool.end();
});

test("register creates a user and returns tokens without password_hash", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
  expect(res.statusCode).toBe(201);
  const body = res.json();
  expect(body.user.username).toBe("pingu");
  expect(body.user).not.toHaveProperty("password_hash");
  expect(body.tokens.accessToken).toBeTruthy();
  expect(body.tokens.refreshToken).toBeTruthy();
});

test("duplicate username is rejected with 409", async () => {
  const payload = { username: "pingu", display_name: "Pingu", password: "noot123" };
  await app.inject({ method: "POST", url: "/auth/register", payload });
  const res = await app.inject({ method: "POST", url: "/auth/register", payload });
  expect(res.statusCode).toBe(409);
  expect(res.json().error).toBe("username_taken");
});

test("invalid payload is rejected with 400", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "x", display_name: "", password: "1" },
  });
  expect(res.statusCode).toBe(400);
});
```

- [ ] **Step 12: Run it to verify it fails, then passes**

Run: `npm test -- test/auth.register.test.ts`
Expected: after implementation above, PASS (3 tests).

- [ ] **Step 13: Commit**

```bash
git add -A
git commit -m "feat: argon2 passwords, JWT tokens, POST /auth/register"
```

---

## Task 4: Login, refresh, auth plugin, /me

**Files:**
- Create: `src/plugins/auth.ts`
- Modify: `src/modules/auth/auth.routes.ts` (add login, refresh, /me GET+PATCH)
- Modify: `src/app.ts` (register auth plugin)
- Create: `test/auth.login.test.ts`, `test/auth.me.test.ts`

**Interfaces:**
- Consumes: `verifyAccess` (Task 3), `login`/`refresh`/`getMe`/`updateMe` (Task 3), schemas (Task 3).
- Produces:
  - `requireAuth` Fastify plugin decorating requests with `request.userId: string`; rejects missing/invalid `Authorization: Bearer <accessToken>` with 401. A route opts in with `{ preHandler: app.requireAuth }`.

- [ ] **Step 1: Create `src/plugins/auth.ts`**

```ts
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Config } from "../config.js";
import { AppError } from "../lib/errors.js";
import { verifyAccess } from "../modules/auth/tokens.js";

declare module "fastify" {
  interface FastifyRequest {
    userId?: string;
  }
  interface FastifyInstance {
    requireAuth: (req: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

export function registerAuthPlugin(app: FastifyInstance, config: Config) {
  app.decorate("requireAuth", async (req: FastifyRequest, _reply: FastifyReply) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      throw new AppError(401, "unauthorized", "Missing bearer token");
    }
    const token = header.slice("Bearer ".length);
    try {
      req.userId = verifyAccess(token, config).sub;
    } catch {
      throw new AppError(401, "unauthorized", "Invalid access token");
    }
  });
}
```

- [ ] **Step 2: Modify `src/app.ts` — register the auth plugin before routes**

Add import and call inside `buildApp`, after the error handler:

```ts
import { registerAuthPlugin } from "./plugins/auth.js";
// ...
  registerAuthPlugin(app, deps.config);
```

- [ ] **Step 3: Modify `src/modules/auth/auth.routes.ts` — add login/refresh/me**

Replace the file with:

```ts
import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { loginSchema, refreshSchema, registerSchema, updateMeSchema } from "./auth.schema.js";
import { getMe, login, refresh, register, updateMe } from "./auth.service.js";

interface Opts {
  pool: Pool;
  config: Config;
}

export async function authRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, config } = opts;

  app.post("/auth/register", async (req, reply) => {
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    reply.code(201);
    return register(pool, config, parsed.data);
  });

  app.post("/auth/login", async (req) => {
    const parsed = loginSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return login(pool, config, parsed.data);
  });

  app.post("/auth/refresh", async (req) => {
    const parsed = refreshSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return refresh(pool, config, parsed.data.refreshToken);
  });

  app.get("/me", { preHandler: app.requireAuth }, async (req) => {
    return { user: await getMe(pool, req.userId!) };
  });

  app.patch("/me", { preHandler: app.requireAuth }, async (req) => {
    const parsed = updateMeSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return { user: await updateMe(pool, req.userId!, parsed.data) };
  });
}
```

- [ ] **Step 4: Write the failing test — `test/auth.login.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await app.close(); await pool.end(); });

async function makeUser() {
  return app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
}

test("login with correct credentials returns tokens", async () => {
  await makeUser();
  const res = await app.inject({
    method: "POST",
    url: "/auth/login",
    payload: { username: "pingu", password: "noot123" },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().tokens.accessToken).toBeTruthy();
});

test("login with wrong password returns 401", async () => {
  await makeUser();
  const res = await app.inject({
    method: "POST",
    url: "/auth/login",
    payload: { username: "pingu", password: "wrong" },
  });
  expect(res.statusCode).toBe(401);
  expect(res.json().error).toBe("invalid_credentials");
});

test("refresh returns a fresh token pair", async () => {
  const reg = (await makeUser()).json();
  const res = await app.inject({
    method: "POST",
    url: "/auth/refresh",
    payload: { refreshToken: reg.tokens.refreshToken },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().tokens.accessToken).toBeTruthy();
  expect(res.json().tokens.refreshToken).toBeTruthy();
});

test("refresh with garbage token returns 401", async () => {
  const res = await app.inject({
    method: "POST",
    url: "/auth/refresh",
    payload: { refreshToken: "not-a-jwt" },
  });
  expect(res.statusCode).toBe(401);
});
```

- [ ] **Step 5: Write the failing test — `test/auth.me.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await app.close(); await pool.end(); });

async function registerAndToken() {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username: "pingu", display_name: "Pingu", password: "noot123" },
  });
  return res.json().tokens.accessToken as string;
}

test("GET /me without token returns 401", async () => {
  const res = await app.inject({ method: "GET", url: "/me" });
  expect(res.statusCode).toBe(401);
});

test("GET /me with token returns the current user", async () => {
  const token = await registerAndToken();
  const res = await app.inject({
    method: "GET",
    url: "/me",
    headers: { authorization: `Bearer ${token}` },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().user.username).toBe("pingu");
  expect(res.json().user).not.toHaveProperty("password_hash");
});

test("PATCH /me updates the signature", async () => {
  const token = await registerAndToken();
  const res = await app.inject({
    method: "PATCH",
    url: "/me",
    headers: { authorization: `Bearer ${token}` },
    payload: { signature: "Noot noot" },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().user.signature).toBe("Noot noot");
});
```

- [ ] **Step 6: Run the tests**

Run: `npm test -- test/auth.login.test.ts test/auth.me.test.ts`
Expected: PASS (7 tests total).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: login, refresh rotation, requireAuth plugin, GET/PATCH /me"
```

---

## Task 5: session-registry seam (no-op)

**Files:**
- Create: `src/modules/session-registry/session-registry.ts`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `SessionRegistry` interface: `notify(userId: string, event: string, payload: unknown): Promise<void>`.
  - `NoopSessionRegistry` implementing it (does nothing). Plan 2 supplies a Redis-backed implementation with the same interface.

- [ ] **Step 1: Create `src/modules/session-registry/session-registry.ts`**

```ts
/**
 * Cross-instance live-event fan-out. In Plan 1 this is a no-op; Plan 2 replaces
 * the implementation with a Redis pub/sub version. Consumers depend only on the
 * interface so no consumer changes when the real one lands.
 */
export interface SessionRegistry {
  notify(userId: string, event: string, payload: unknown): Promise<void>;
}

export class NoopSessionRegistry implements SessionRegistry {
  async notify(): Promise<void> {
    // no-op in Plan 1
  }
}
```

- [ ] **Step 2: Modify `src/app.ts` — add `registry` to `AppDeps` and default it**

Change `AppDeps` and `buildApp`:

```ts
import type { SessionRegistry } from "./modules/session-registry/session-registry.js";
import { NoopSessionRegistry } from "./modules/session-registry/session-registry.js";

export interface AppDeps {
  pool: Pool;
  config: Config;
  registry?: SessionRegistry;
}
```

Inside `buildApp`, before registering routes:

```ts
  const registry = deps.registry ?? new NoopSessionRegistry();
```

(Keep `registry` available to pass into contacts routes in Task 6.)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "feat: session-registry interface with no-op implementation"
```

---

## Task 6: Contacts — friend requests, accept/decline, contact list

**Files:**
- Create: `src/modules/contacts/contacts.schema.ts`, `src/modules/contacts/contacts.repo.ts`, `src/modules/contacts/contacts.service.ts`, `src/modules/contacts/contacts.routes.ts`
- Modify: `src/app.ts` (register contacts routes with pool + registry)
- Create: `test/contacts.test.ts`

**Interfaces:**
- Consumes: `Pool`, `requireAuth` (Task 4), `SessionRegistry` (Task 5), `findByUsername`/`findById` (Task 3), `PublicUser` (Task 3).
- Produces:
  - `contactsRoutes` plugin providing `GET /contacts`, `GET /friend-requests`, `POST /friend-requests`, `POST /friend-requests/:id/accept`, `POST /friend-requests/:id/decline`.
  - `Contact = PublicUser & { presence: "online" | "away" | "offline" }` — presence hardcoded `"offline"` in Plan 1 (real presence comes from Redis in Plan 2).

- [ ] **Step 1: Create `src/modules/contacts/contacts.schema.ts`**

```ts
import { z } from "zod";

export const sendRequestSchema = z.object({
  username: z.string().min(1),
  message: z.string().max(140).optional(),
});
```

- [ ] **Step 2: Create `src/modules/contacts/contacts.repo.ts`**

```ts
import type { Pool } from "pg";
import type { PublicUser } from "../auth/auth.repo.js";

export interface FriendRequestRow {
  id: string;
  from_user: string;
  to_user: string;
  message: string | null;
  status: "pending" | "accepted" | "declined";
  created_at: string;
}

export async function insertRequest(
  pool: Pool,
  fromUser: string,
  toUser: string,
  message: string | null
): Promise<FriendRequestRow> {
  const res = await pool.query<FriendRequestRow>(
    `INSERT INTO friend_requests (from_user, to_user, message, status)
     VALUES ($1, $2, $3, 'pending') RETURNING *`,
    [fromUser, toUser, message]
  );
  return res.rows[0];
}

export async function findPendingBetween(
  pool: Pool,
  fromUser: string,
  toUser: string
): Promise<FriendRequestRow | null> {
  const res = await pool.query<FriendRequestRow>(
    `SELECT * FROM friend_requests
     WHERE from_user = $1 AND to_user = $2 AND status = 'pending'`,
    [fromUser, toUser]
  );
  return res.rows[0] ?? null;
}

export async function listIncomingPending(pool: Pool, userId: string): Promise<FriendRequestRow[]> {
  const res = await pool.query<FriendRequestRow>(
    `SELECT * FROM friend_requests
     WHERE to_user = $1 AND status = 'pending' ORDER BY created_at DESC`,
    [userId]
  );
  return res.rows;
}

export async function findRequestById(pool: Pool, id: string): Promise<FriendRequestRow | null> {
  const res = await pool.query<FriendRequestRow>("SELECT * FROM friend_requests WHERE id = $1", [id]);
  return res.rows[0] ?? null;
}

export async function setRequestStatus(
  pool: Pool,
  id: string,
  status: "accepted" | "declined"
): Promise<void> {
  await pool.query("UPDATE friend_requests SET status = $2 WHERE id = $1", [id, status]);
}

/** Insert friendship as an ordered pair (user_a < user_b). Idempotent. */
export async function insertFriendship(pool: Pool, x: string, y: string): Promise<void> {
  const [a, b] = x < y ? [x, y] : [y, x];
  await pool.query(
    `INSERT INTO friendships (user_a, user_b) VALUES ($1, $2)
     ON CONFLICT (user_a, user_b) DO NOTHING`,
    [a, b]
  );
}

export async function areFriends(pool: Pool, x: string, y: string): Promise<boolean> {
  const [a, b] = x < y ? [x, y] : [y, x];
  const res = await pool.query(
    "SELECT 1 FROM friendships WHERE user_a = $1 AND user_b = $2",
    [a, b]
  );
  return res.rowCount! > 0;
}

export async function listFriends(pool: Pool, userId: string): Promise<PublicUser[]> {
  const res = await pool.query<PublicUser>(
    `SELECT u.id, u.username, u.display_name, u.avatar_url, u.signature, u.created_at
     FROM friendships f
     JOIN users u
       ON u.id = CASE WHEN f.user_a = $1 THEN f.user_b ELSE f.user_a END
     WHERE f.user_a = $1 OR f.user_b = $1
     ORDER BY u.display_name`,
    [userId]
  );
  return res.rows;
}
```

- [ ] **Step 3: Create `src/modules/contacts/contacts.service.ts`**

```ts
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import { findById, findByUsername, type PublicUser } from "../auth/auth.repo.js";
import {
  areFriends,
  findPendingBetween,
  findRequestById,
  insertFriendship,
  insertRequest,
  listFriends,
  listIncomingPending,
  setRequestStatus,
  type FriendRequestRow,
} from "./contacts.repo.js";

export type Contact = PublicUser & { presence: "online" | "away" | "offline" };

export async function sendRequest(
  pool: Pool,
  registry: SessionRegistry,
  fromUser: string,
  targetUsername: string,
  message: string | null
): Promise<FriendRequestRow> {
  const target = await findByUsername(pool, targetUsername);
  if (!target) throw new AppError(404, "not_found", "No such user");
  if (target.id === fromUser) throw new AppError(400, "self_request", "Cannot add yourself");
  if (await areFriends(pool, fromUser, target.id))
    throw new AppError(409, "already_friends", "Already friends");
  const dup = await findPendingBetween(pool, fromUser, target.id);
  if (dup) throw new AppError(409, "request_exists", "Request already pending");

  const request = await insertRequest(pool, fromUser, target.id, message);
  await registry.notify(target.id, "friend:request", { request });
  return request;
}

export async function listRequests(pool: Pool, userId: string): Promise<FriendRequestRow[]> {
  return listIncomingPending(pool, userId);
}

export async function acceptRequest(
  pool: Pool,
  registry: SessionRegistry,
  userId: string,
  requestId: string
): Promise<{ friendId: string }> {
  const req = await findRequestById(pool, requestId);
  if (!req || req.status !== "pending") throw new AppError(404, "not_found", "No pending request");
  if (req.to_user !== userId) throw new AppError(403, "forbidden", "Not your request to accept");
  await insertFriendship(pool, req.from_user, req.to_user);
  await setRequestStatus(pool, requestId, "accepted");
  await registry.notify(req.from_user, "friend:accepted", { friendId: req.to_user });
  return { friendId: req.from_user };
}

export async function declineRequest(
  pool: Pool,
  userId: string,
  requestId: string
): Promise<void> {
  const req = await findRequestById(pool, requestId);
  if (!req || req.status !== "pending") throw new AppError(404, "not_found", "No pending request");
  if (req.to_user !== userId) throw new AppError(403, "forbidden", "Not your request to decline");
  await setRequestStatus(pool, requestId, "declined");
}

export async function listContacts(pool: Pool, userId: string): Promise<Contact[]> {
  const friends = await listFriends(pool, userId);
  // Presence is hardcoded offline in Plan 1; Plan 2 populates from Redis.
  return friends.map((f) => ({ ...f, presence: "offline" as const }));
}

// Re-export so routes need only import this module.
export { findById };
```

- [ ] **Step 4: Create `src/modules/contacts/contacts.routes.ts`**

```ts
import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import { sendRequestSchema } from "./contacts.schema.js";
import {
  acceptRequest,
  declineRequest,
  listContacts,
  listRequests,
  sendRequest,
} from "./contacts.service.js";

interface Opts {
  pool: Pool;
  registry: SessionRegistry;
}

export async function contactsRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, registry } = opts;

  app.get("/contacts", { preHandler: app.requireAuth }, async (req) => {
    return listContacts(pool, req.userId!);
  });

  app.get("/friend-requests", { preHandler: app.requireAuth }, async (req) => {
    return listRequests(pool, req.userId!);
  });

  app.post("/friend-requests", { preHandler: app.requireAuth }, async (req, reply) => {
    const parsed = sendRequestSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    reply.code(201);
    const request = await sendRequest(
      pool,
      registry,
      req.userId!,
      parsed.data.username,
      parsed.data.message ?? null
    );
    return { request };
  });

  app.post("/friend-requests/:id/accept", { preHandler: app.requireAuth }, async (req) => {
    const { id } = req.params as { id: string };
    return acceptRequest(pool, registry, req.userId!, id);
  });

  app.post("/friend-requests/:id/decline", { preHandler: app.requireAuth }, async (req) => {
    const { id } = req.params as { id: string };
    await declineRequest(pool, req.userId!, id);
    return { ok: true };
  });
}
```

- [ ] **Step 5: Modify `src/app.ts` — register contacts routes**

Add import and registration (using the `registry` created in Task 5 Step 2):

```ts
import { contactsRoutes } from "./modules/contacts/contacts.routes.js";
// ...
  app.register(contactsRoutes, { pool: deps.pool, registry });
```

- [ ] **Step 6: Write the failing test — `test/contacts.test.ts`**

```ts
import { beforeAll, beforeEach, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
const app = makeApp(pool);

beforeAll(async () => { await runMigrations(pool); });
beforeEach(async () => { await resetDb(pool); });
afterAll(async () => { await app.close(); await pool.end(); });

async function register(username: string) {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  const body = res.json();
  return { id: body.user.id as string, token: body.tokens.accessToken as string };
}
function auth(token: string) {
  return { authorization: `Bearer ${token}` };
}

test("full friend flow: request -> incoming -> accept -> contacts", async () => {
  const a = await register("alice");
  const b = await register("bob");

  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob", message: "hi" },
  });
  expect(send.statusCode).toBe(201);
  const requestId = send.json().request.id;

  const incoming = await app.inject({
    method: "GET",
    url: "/friend-requests",
    headers: auth(b.token),
  });
  expect(incoming.json()).toHaveLength(1);

  const accept = await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: auth(b.token),
  });
  expect(accept.statusCode).toBe(200);

  const aContacts = await app.inject({ method: "GET", url: "/contacts", headers: auth(a.token) });
  const bContacts = await app.inject({ method: "GET", url: "/contacts", headers: auth(b.token) });
  expect(aContacts.json().map((c: any) => c.username)).toEqual(["bob"]);
  expect(bContacts.json().map((c: any) => c.username)).toEqual(["alice"]);
  expect(aContacts.json()[0].presence).toBe("offline");
});

test("cannot friend-request a nonexistent user", async () => {
  const a = await register("alice");
  const res = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "ghost" },
  });
  expect(res.statusCode).toBe(404);
});

test("duplicate pending request is rejected", async () => {
  const a = await register("alice");
  await register("bob");
  const payload = { username: "bob" };
  await app.inject({ method: "POST", url: "/friend-requests", headers: auth(a.token), payload });
  const res = await app.inject({ method: "POST", url: "/friend-requests", headers: auth(a.token), payload });
  expect(res.statusCode).toBe(409);
});

test("cannot accept someone else's request", async () => {
  const a = await register("alice");
  await register("bob");
  const carol = await register("carol");
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob" },
  });
  const requestId = send.json().request.id;
  const res = await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: auth(carol.token),
  });
  expect(res.statusCode).toBe(403);
});

test("decline removes the request from incoming", async () => {
  const a = await register("alice");
  const b = await register("bob");
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: auth(a.token),
    payload: { username: "bob" },
  });
  const requestId = send.json().request.id;
  await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/decline`,
    headers: auth(b.token),
  });
  const incoming = await app.inject({ method: "GET", url: "/friend-requests", headers: auth(b.token) });
  expect(incoming.json()).toHaveLength(0);
});
```

- [ ] **Step 7: Run the tests**

Run: `npm test -- test/contacts.test.ts`
Expected: PASS (5 tests).

- [ ] **Step 8: Run the full suite**

Run: `npm test`
Expected: PASS (all files: health, migrate, register, login, me, contacts).

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: contacts module — friend requests, accept/decline, contact list"
```

---

## Task 7: Rate limiting, CORS, containerized boot verification

**Files:**
- Modify: `src/app.ts` (register `@fastify/cors` and `@fastify/rate-limit` on auth routes)
- Create: `test/ratelimit.test.ts`

**Interfaces:**
- Consumes: everything above.
- Produces: no new public interface — hardening only.

- [ ] **Step 1: Modify `src/app.ts` — register cors + rate limit**

Add near the top of `buildApp`, before routes:

```ts
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
// ...
  await app.register(cors, { origin: true });
  await app.register(rateLimit, { max: 100, timeWindow: "1 minute" });
```

Note: `buildApp` must now `await` these. Change `buildApp` to `async function buildApp(...)` returning `Promise<FastifyInstance>`, and update `server.ts` (`const app = await buildApp(...)`) and `test/helpers/app.ts` (`makeApp` becomes `async` and returns a promise; update tests to `await makeApp(pool)` inside `beforeAll` — assign `app` in `beforeAll`). Apply these signature changes consistently:

- In `test/helpers/app.ts`: `export async function makeApp(pool: Pool) { return buildApp({ pool, config: testConfig }); }`
- In each test file, change the top-level `const app = makeApp(pool)` to `let app: Awaited<ReturnType<typeof makeApp>>;` and set `app = await makeApp(pool);` inside `beforeAll` (after `runMigrations`).

- [ ] **Step 2: Write the test — `test/ratelimit.test.ts`**

```ts
import { beforeAll, afterAll, expect, test } from "vitest";
import { makeApp, makePool } from "./helpers/app.js";
import { runMigrations } from "../src/db/migrate.js";

const pool = makePool();
let app: Awaited<ReturnType<typeof makeApp>>;

beforeAll(async () => {
  await runMigrations(pool);
  app = await makeApp(pool);
});
afterAll(async () => { await app.close(); await pool.end(); });

test("health endpoint responds and sets rate-limit headers", async () => {
  const res = await app.inject({ method: "GET", url: "/health" });
  expect(res.statusCode).toBe(200);
  expect(res.headers["x-ratelimit-limit"]).toBeDefined();
});
```

- [ ] **Step 3: Run the full suite**

Run: `npm test`
Expected: PASS (all files).

- [ ] **Step 4: Verify the container boots and migrates**

```bash
docker compose up -d --build
docker compose exec api node dist/db/migrate.js
curl -s localhost:3000/health
```
Expected: `{"status":"ok"}`. (If Docker is down, ask the user to start Docker Desktop.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: CORS, rate limiting, container boot verification"
```

---

## Self-Review Notes (author checklist — completed)

- **Spec coverage:** `users`/`friendships`/`friend_requests`/`messages` schema (Task 2) ✔; argon2id + JWT access/refresh with rotation (Tasks 3–4) ✔; register/login/refresh/me + friend-requests/contacts REST surface from §6 ✔; server-side authz (own-request checks, no self-add) ✔; validation at boundary (zod on every payload) ✔; one-row-per-pair friendships + deterministic conversation id ✔; Dockerized backend ✔; rate limiting ✔. **Deferred by design to Plan 2** (not gaps): `GET /conversations/:userId/messages`, presence values, all Socket.IO events, Redis-backed session-registry — seams are in place (`SessionRegistry`, `conversationId`, `messages` table, `presence` field).
- **Placeholder scan:** no TBD/TODO; every code step is complete.
- **Type consistency:** `PublicUser` shape is the single returned user type across auth + contacts; `SessionRegistry.notify` signature identical in interface, no-op, and all call sites; `conversationId` defined once and unused in Plan 1 (reserved for Plan 2) — intentionally shipped early to lock the namespace constant.
