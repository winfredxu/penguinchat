import { afterAll, expect, test } from "vitest";
import { createRedisClients, closeRedisClients } from "../src/realtime/redis.js";

test("createRedisClients connects and PINGs", async () => {
  const c = await createRedisClients("redis://localhost:6379");
  const pong = await c.general.ping();
  expect(pong).toBe("PONG");
  await closeRedisClients(c);
});
