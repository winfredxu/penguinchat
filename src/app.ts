import Fastify, { FastifyInstance } from "fastify";
import cors from "@fastify/cors";
import rateLimit from "@fastify/rate-limit";
import type { Pool } from "pg";
import type { Config } from "./config.js";
import { AppError } from "./lib/errors.js";
import { authRoutes } from "./modules/auth/auth.routes.js";
import { contactsRoutes } from "./modules/contacts/contacts.routes.js";
import { registerAuthPlugin } from "./plugins/auth.js";
import type { SessionRegistry } from "./modules/session-registry/session-registry.js";
import { NoopSessionRegistry } from "./modules/session-registry/session-registry.js";
import type { PresenceReader } from "./modules/presence/presence.service.js";
import { NoopPresenceService } from "./modules/presence/presence.service.js";

export interface AppDeps {
  pool: Pool;
  config: Config;
  registry?: SessionRegistry;
  presence?: PresenceReader;
}

export async function buildApp(deps: AppDeps): Promise<FastifyInstance> {
  const app = Fastify({ logger: false });

  await app.register(cors, { origin: true });
  await app.register(rateLimit, { max: 100, timeWindow: "1 minute" });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof AppError) {
      reply.code(err.status).send({ error: err.code, message: err.message });
      return;
    }
    reply.code(500).send({ error: "internal", message: "Internal server error" });
  });

  const registry = deps.registry ?? new NoopSessionRegistry();
  const presence = deps.presence ?? new NoopPresenceService();

  registerAuthPlugin(app, deps.config);

  app.get("/health", async () => ({ status: "ok" }));
  app.register(authRoutes, { pool: deps.pool, config: deps.config });
  app.register(contactsRoutes, { pool: deps.pool, registry, presence });

  return app;
}
