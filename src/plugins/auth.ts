import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import type { Config } from "../config.js";
import { AppError } from "../lib/errors.js";
import { verifyAccess } from "../modules/auth/tokens.js";

declare module "fastify" {
  interface FastifyRequest {
    userId?: string;
  }
  interface FastifyInstance {
    requireAuth: (req: FastifyRequest, reply: FastifyReply) => Promise<void>;
  }
}

export function registerAuthPlugin(app: FastifyInstance, config: Config) {
  app.decorate("requireAuth", async (req: FastifyRequest, _reply: FastifyReply) => {
    const header = req.headers.authorization;
    if (!header || !header.startsWith("Bearer ")) {
      throw new AppError(401, "unauthorized", "Missing bearer token");
    }
    const token = header.slice("Bearer ".length);
    try {
      req.userId = verifyAccess(token, config).sub;
    } catch {
      throw new AppError(401, "unauthorized", "Invalid access token");
    }
  });
}
