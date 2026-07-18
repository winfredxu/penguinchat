import { Pool } from "pg";
import { loadConfig } from "./config.js";
import { buildApp } from "./app.js";
import { runMigrations } from "./db/migrate.js";
import { createRedisClients, closeRedisClients } from "./realtime/redis.js";
import { PresenceService } from "./modules/presence/presence.service.js";
import { RedisSessionRegistry } from "./modules/session-registry/redis-session-registry.js";
import { createGateway } from "./realtime/gateway.js";

async function main() {
  const config = loadConfig();
  const pool = new Pool({ connectionString: config.databaseUrl });
  await runMigrations(pool);

  const redis = await createRedisClients(config.redisUrl);
  const presence = new PresenceService(redis.general, 30);
  const registry = new RedisSessionRegistry();

  const app = await buildApp({ pool, config, registry, presence });
  await app.listen({ port: config.port, host: "0.0.0.0" });

  const io = createGateway(app.server, {
    config,
    pub: redis.pub,
    sub: redis.sub,
    presence,
    pool,
  });
  registry.attach(io);

  // eslint-disable-next-line no-console
  console.log(`PenguinChat API + realtime listening on :${config.port}`);

  const shutdown = async () => {
    io.close();
    await app.close();
    await closeRedisClients(redis);
    await pool.end();
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
