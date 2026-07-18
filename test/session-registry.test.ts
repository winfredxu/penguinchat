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
