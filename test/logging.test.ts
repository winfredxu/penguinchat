import { afterEach, expect, test } from "vitest";
import type { Pool } from "pg";
import { buildApp } from "../src/app.js";
import { testConfig } from "./helpers/app.js";

const apps: Array<Awaited<ReturnType<typeof buildApp>>> = [];

afterEach(async () => {
  await Promise.all(apps.splice(0).map((app) => app.close()));
});

test("requests emit structured logs at the configured level", async () => {
  const lines: string[] = [];
  const app = await buildApp({
    pool: {} as Pool,
    config: { ...testConfig, logLevel: "info" },
    logStream: { write: (message) => lines.push(message) },
  });
  apps.push(app);

  const response = await app.inject({ method: "GET", url: "/health" });
  expect(response.statusCode).toBe(200);

  const entries = lines.map((line) => JSON.parse(line));
  expect(entries).toEqual(
    expect.arrayContaining([
      expect.objectContaining({ level: 30, msg: "incoming request" }),
      expect.objectContaining({ level: 30, msg: "request completed" }),
    ])
  );
});
