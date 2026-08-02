import { afterAll, expect, test } from "vitest";
import jwt from "jsonwebtoken";
import { makeRealtimeStack, socketClient, registerUser, type RealtimeStack } from "./helpers/realtime.js";
import { testConfig } from "./helpers/app.js";

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

test("token without a sub claim is rejected (FU-13)", async () => {
  // A validly-signed access token that lacks sub. Without the guard the socket
  // would connect and join a room literally named "undefined".
  const token = jwt.sign({}, testConfig.jwtAccessSecret, { expiresIn: "15m" });
  await expect(socketClient(stack.port, token)).rejects.toThrow();
});
