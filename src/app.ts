import Fastify, { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "./config.js";
import { AppError } from "./lib/errors.js";
import { authRoutes } from "./modules/auth/auth.routes.js";

export interface AppDeps {
  pool: Pool;
  config: Config;
}

export function buildApp(deps: AppDeps): FastifyInstance {
  const app = Fastify({ logger: false });

  app.setErrorHandler((err, _req, reply) => {
    if (err instanceof AppError) {
      reply.code(err.status).send({ error: err.code, message: err.message });
      return;
    }
    reply.code(500).send({ error: "internal", message: "Internal server error" });
  });

  app.get("/health", async () => ({ status: "ok" }));
  app.register(authRoutes, { pool: deps.pool, config: deps.config });

  return app;
}
