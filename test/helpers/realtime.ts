import { io as ioc, type Socket as ClientSocket } from "socket.io-client";
import { Server } from "socket.io";
import { makePool, testConfig } from "./app.js";
import { resetDb } from "./db.js";
import { runMigrations } from "../../src/db/migrate.js";
import { createRedisClients, closeRedisClients } from "../../src/realtime/redis.js";

export interface RealtimeStack {
  app: Awaited<ReturnType<typeof import("../../src/app.js").buildApp>>;
  io: Server;
  port: number;
  cleanup: () => Promise<void>;
}

export async function makeRealtimeStack(): Promise<RealtimeStack> {
  const pool = makePool();
  await runMigrations(pool);
  await resetDb(pool);
  const redis = await createRedisClients(testConfig.redisUrl);
  const { buildApp } = await import("../../src/app.js");
  const app = await buildApp({ pool, config: testConfig });
  await app.listen({ port: 0, host: "127.0.0.1" });
  const port = app.server.address().port;
  const io = new Server(app.server, { cors: { origin: "*" } });
  return {
    app,
    io,
    port,
    cleanup: async () => {
      io.close();
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

/** Register a user via REST and return { id, accessToken }. */
export async function registerUser(
  app: RealtimeStack["app"],
  username: string
): Promise<{ id: string; accessToken: string }> {
  const res = await app.inject({
    method: "POST",
    url: "/auth/register",
    payload: { username, display_name: username, password: "noot123" },
  });
  const body = res.json();
  return { id: body.user.id, accessToken: body.tokens.accessToken };
}
