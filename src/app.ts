import Fastify, { FastifyInstance } from "fastify";
import type { Pool } from "pg";

export interface AppDeps {
  pool: Pool;
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({ logger: false });

  app.get("/health", async () => ({ status: "ok" }));

  // Routes are registered by later tasks:
  // app.register(authRoutes, { deps });
  // app.register(contactsRoutes, { deps });

  return app;
}
