import { afterAll, beforeAll, expect, test } from "vitest";
import { corsOriginOption } from "../src/lib/cors.js";
import { buildApp } from "../src/app.js";
import { makePool, testConfig } from "./helpers/app.js";
import { resetDb } from "./helpers/db.js";
import { runMigrations } from "../src/db/migrate.js";
import type { Config } from "../src/config.js";

const pool = makePool();
beforeAll(async () => { await runMigrations(pool); });
afterAll(async () => { await pool.end(); });

type OriginFn = (
  origin: string,
  cb: (err: Error | null, ok?: boolean) => void
) => void;

test("corsOriginOption: empty list reflects all (true)", () => {
  expect(corsOriginOption([])).toBe(true);
});

test("corsOriginOption: allowlist allows listed + no-origin, rejects others (FU-3)", async () => {
  const opt = corsOriginOption(["http://localhost:5173"]) as OriginFn;
  await new Promise<void>((r) =>
    opt("http://localhost:5173", (e, ok) => {
      expect(e).toBeNull();
      expect(ok).toBe(true);
      r();
    })
  );
  // No Origin header (same-origin / non-CORS request) is allowed.
  await new Promise<void>((r) =>
    opt(undefined as unknown as string, (e, ok) => {
      expect(e).toBeNull();
      expect(ok).toBe(true);
      r();
    })
  );
  await new Promise<void>((r) =>
    opt("http://evil.com", (e, ok) => {
      expect(e).toBeInstanceOf(Error);
      expect(ok).toBe(false);
      r();
    })
  );
});

test("REST CORS reflects an allowed origin and omits a disallowed one (FU-3)", async () => {
  await resetDb(pool);
  const cfg: Config = { ...testConfig, corsOrigins: ["http://localhost:5173"] };
  const app = await buildApp({ pool, config: cfg });
  const allowed = await app.inject({
    method: "GET",
    url: "/health",
    headers: { origin: "http://localhost:5173" },
  });
  expect(allowed.headers["access-control-allow-origin"]).toBe("http://localhost:5173");
  const blocked = await app.inject({
    method: "GET",
    url: "/health",
    headers: { origin: "http://evil.com" },
  });
  expect(blocked.headers["access-control-allow-origin"]).toBeUndefined();
  await app.close();
});
