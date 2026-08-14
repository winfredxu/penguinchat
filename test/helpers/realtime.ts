import type { FastifyInstance } from "fastify";
import { io as ioc, type Socket as ClientSocket } from "socket.io-client";
import { Server } from "socket.io";
import type { Pool } from "pg";
import { makePool, testConfig } from "./app.js";
import { resetDb } from "./db.js";
import { runMigrations } from "../../src/db/migrate.js";
import { createRedisClients, closeRedisClients, type RedisClients } from "../../src/realtime/redis.js";
import { PresenceService } from "../../src/modules/presence/presence.service.js";

export interface RealtimeStack {
  app: Awaited<ReturnType<typeof import("../../src/app.js").buildApp>>;
  io: Server;
  port: number;
  pool: Pool;
  presence: PresenceService;
  registry: import("../../src/modules/session-registry/redis-session-registry.js").RedisSessionRegistry;
  cleanup: () => Promise<void>;
}

export async function makeRealtimeStack(): Promise<RealtimeStack> {
  const pool = makePool();
  await runMigrations(pool);
  await resetDb(pool);
  const redis = await createRedisClients(testConfig.redisUrl);
  const { RedisSessionRegistry } = await import("../../src/modules/session-registry/redis-session-registry.js");
  const registry = new RedisSessionRegistry();
  const { buildApp } = await import("../../src/app.js");
  const presence = new PresenceService(redis.general, 30);
  const app = await buildApp({ pool, config: testConfig, registry, presence });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const { createGateway } = await import("../../src/realtime/gateway.js");
  const io = createGateway(app.server, {
    config: testConfig,
    pub: redis.pub,
    sub: redis.sub,
    presence,
    pool,
  });
  const { registerMessagingHandlers } = await import("../../src/modules/messaging/messaging.handlers.js");
  registerMessagingHandlers(io, { pool, registry });
  registry.attach(io);
  return {
    app,
    io,
    port,
    pool,
    presence,
    registry,
    cleanup: async () => {
      await io.close();
      // Allow in-flight disconnect handlers to finish before closing redis.
      await new Promise((r) => setTimeout(r, 100));
      await app.close();
      await closeRedisClients(redis);
      await pool.end();
    },
  };
}

export function socketClient(port: number, token: string): Promise<ClientSocket> {
  return new Promise((resolve, reject) => {
    const sock = ioc(`http://localhost:${port}`, { auth: { token } });
    sock.on("connect", () => resolve(sock));
    sock.on("connect_error", (err) => {
      sock.disconnect();
      reject(err);
    });
  });
}

/** Register a user via REST and return { id, accessToken, username }. */
export async function registerUser(
  app: RealtimeStack["app"],
  username: string
): Promise<{ id: string; accessToken: string; username: string }> {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  const body = res.json();
  return { id: body.user.id, accessToken: body.tokens.accessToken, username };
}

/** Emit a socket event and resolve its ack. */
export function emitAck(
  sock: ClientSocket,
  event: string,
  payload: unknown
): Promise<unknown> {
  return new Promise((resolve) => {
    sock.emit(event, payload, (ack: unknown) => resolve(ack));
  });
}

/**
 * Two independent HTTP + Socket.IO stacks sharing one Postgres and one Redis.
 * Each instance gets its OWN redis pub/sub clients (mirrors production: each
 * process has its own clients), but they connect to the same Redis so the
 * @socket.io/redis-adapter fans emits out between instances. Used to prove the
 * cross-instance fan-out path that presence + messaging rely on (FU-12).
 */
export interface MultiInstanceStack {
  apps: [FastifyInstance, FastifyInstance];
  ios: [Server, Server];
  ports: [number, number];
  pool: Pool;
  cleanup: () => Promise<void>;
}

async function makeInstance(
  pool: Pool,
  redis: RedisClients
): Promise<{ app: FastifyInstance; io: Server; port: number }> {
  const { RedisSessionRegistry } = await import("../../src/modules/session-registry/redis-session-registry.js");
  const registry = new RedisSessionRegistry();
  const { buildApp } = await import("../../src/app.js");
  const presence = new PresenceService(redis.general, 30);
  const app = await buildApp({ pool, config: testConfig, registry, presence });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const { createGateway } = await import("../../src/realtime/gateway.js");
  const io = createGateway(app.server, {
    config: testConfig,
    pub: redis.pub,
    sub: redis.sub,
    presence,
    pool,
  });
  const { registerMessagingHandlers } = await import("../../src/modules/messaging/messaging.handlers.js");
  registerMessagingHandlers(io, { pool, registry });
  registry.attach(io);
  return { app, io, port };
}

export async function makeMultiInstanceStack(): Promise<MultiInstanceStack> {
  const pool = makePool();
  await runMigrations(pool);
  await resetDb(pool);
  const redisA = await createRedisClients(testConfig.redisUrl);
  const redisB = await createRedisClients(testConfig.redisUrl);
  const instA = await makeInstance(pool, redisA);
  const instB = await makeInstance(pool, redisB);
  return {
    apps: [instA.app, instB.app],
    ios: [instA.io, instB.io],
    ports: [instA.port, instB.port],
    pool,
    cleanup: async () => {
      await instA.io.close();
      await instB.io.close();
      // Let in-flight disconnect handlers settle before closing redis/clients.
      await new Promise((r) => setTimeout(r, 100));
      await instA.app.close();
      await instB.app.close();
      await closeRedisClients(redisA);
      await closeRedisClients(redisB);
      await pool.end();
    },
  };
}
