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
