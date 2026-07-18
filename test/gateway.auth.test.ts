import { afterAll, expect, test } from "vitest";
import { makeRealtimeStack, socketClient, registerUser, type RealtimeStack } from "./helpers/realtime.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("valid JWT connects and the socket joins its userId room", async () => {
  stack = await makeRealtimeStack();
  const { accessToken, id } = await registerUser(stack.app, "alice");
  const sock = await socketClient(stack.port, accessToken);
  expect(sock.connected).toBe(true);
  // The server-side socket should be in the room named by the userId.
  const inRoom = await stack.io.in(id).fetchSockets();
  expect(inRoom.length).toBe(1);
  sock.disconnect();
});

test("registry.notify delivers an event to the connected user's socket", async () => {
  // Exercises the RedisSessionRegistry's real emit path now that the gateway
  // authenticates + room-joins the socket (Task 2 only tested the lazy no-op).
  const { RedisSessionRegistry } = await import("../src/modules/session-registry/redis-session-registry.js");
  const registry = new RedisSessionRegistry();
  registry.attach(stack.io);
  const { accessToken, id } = await registerUser(stack.app, "bob");
  const sock = await socketClient(stack.port, accessToken);
  const received = new Promise((r) => sock.on("friend:request", r));
  await registry.notify(id, "friend:request", { request: { id: "r1" } });
  expect(await received).toEqual({ request: { id: "r1" } });
  sock.disconnect();
});

test("missing token is rejected", async () => {
  await expect(socketClient(stack.port, "")).rejects.toThrow();
});

test("invalid token is rejected", async () => {
  await expect(socketClient(stack.port, "not-a-jwt")).rejects.toThrow();
});
