import { afterAll, expect, test } from "vitest";
import { createRedisClients, closeRedisClients, type RedisClients } from "../src/realtime/redis.js";

test("createRedisClients connects and PINGs", async () => {
  const c = await createRedisClients("redis://localhost:6379");
  const pong = await c.general.ping();
  expect(pong).toBe("PONG");
  await closeRedisClients(c);
});

test("closeRedisClients resolves even if a client's quit rejects (FU-14)", async () => {
  // If one client is already in an error state, Promise.all would reject and
  // leave the other quits un-awaited (connection leak). allSettled waits for all.
  const fake = {
    pub: { quit: () => Promise.reject(new Error("pub already closed")) },
    sub: { quit: () => Promise.resolve("OK") },
    general: { quit: () => Promise.resolve("OK") },
  } as unknown as RedisClients;
  await expect(closeRedisClients(fake)).resolves.toBeUndefined();
});
