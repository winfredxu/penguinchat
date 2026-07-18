import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { registerSchema } from "./auth.schema.js";
import { register } from "./auth.service.js";

interface Opts {
  pool: Pool;
  config: Config;
}

export async function authRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, config } = opts;

  app.post("/auth/register", async (req, reply) => {
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    const result = await register(pool, config, parsed.data);
    reply.code(201);
    return result;
  });
}
