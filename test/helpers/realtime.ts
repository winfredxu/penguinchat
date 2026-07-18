import { io as ioc, type Socket as ClientSocket } from "socket.io-client";
import { Server } from "socket.io";
import type { Pool } from "pg";
import { makePool, testConfig } from "./app.js";
import { resetDb } from "./db.js";
import { runMigrations } from "../../src/db/migrate.js";
import { createRedisClients, closeRedisClients } from "../../src/realtime/redis.js";
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
