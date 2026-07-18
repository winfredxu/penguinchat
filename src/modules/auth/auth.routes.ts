import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import type { Config } from "../../config.js";
import { AppError } from "../../lib/errors.js";
import { loginSchema, refreshSchema, registerSchema, updateMeSchema } from "./auth.schema.js";
import { getMe, login, refresh, register, updateMe } from "./auth.service.js";

interface Opts {
  pool: Pool;
  config: Config;
}

export async function authRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, config } = opts;

  app.post("/auth/register", async (req, reply) => {
    const parsed = registerSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    reply.code(201);
    return register(pool, config, parsed.data);
  });

  app.post("/auth/login", async (req) => {
    const parsed = loginSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return login(pool, config, parsed.data);
  });

  app.post("/auth/refresh", async (req) => {
    const parsed = refreshSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return refresh(pool, config, parsed.data.refreshToken);
  });

  app.get("/me", { preHandler: app.requireAuth }, async (req) => {
    return { user: await getMe(pool, req.userId!) };
  });

  app.patch("/me", { preHandler: app.requireAuth }, async (req) => {
    const parsed = updateMeSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    return { user: await updateMe(pool, req.userId!, parsed.data) };
  });
}
