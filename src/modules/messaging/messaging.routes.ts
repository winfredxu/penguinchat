import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import { listHistory } from "./messaging.service.js";

interface Opts {
  pool: Pool;
}

export async function messagingRoutes(app: FastifyInstance, opts: Opts) {
  app.get("/conversations/:peerId/messages", { preHandler: app.requireAuth }, async (req) => {
    const { peerId } = req.params as { peerId: string };
    const query = req.query as { before?: string; limit?: string };
    let limit: number | undefined;
    if (query.limit !== undefined) {
      limit = Number(query.limit);
      if (!Number.isFinite(limit) || limit <= 0) {
        throw new AppError(400, "invalid_payload", "limit must be a positive number");
      }
    }
    const messages = await listHistory(opts.pool, req.userId!, peerId, {
      before: query.before,
      limit,
    });
    return { messages };
  });
}
