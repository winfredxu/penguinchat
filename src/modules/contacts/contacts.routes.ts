import type { FastifyInstance } from "fastify";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import { sendRequestSchema } from "./contacts.schema.js";
import {
  acceptRequest,
  declineRequest,
  listContacts,
  listRequests,
  sendRequest,
} from "./contacts.service.js";

interface Opts {
  pool: Pool;
  registry: SessionRegistry;
}

export async function contactsRoutes(app: FastifyInstance, opts: Opts) {
  const { pool, registry } = opts;

  app.get("/contacts", { preHandler: app.requireAuth }, async (req) => {
    return listContacts(pool, req.userId!);
  });

  app.get("/friend-requests", { preHandler: app.requireAuth }, async (req) => {
    return listRequests(pool, req.userId!);
  });

  app.post("/friend-requests", { preHandler: app.requireAuth }, async (req, reply) => {
    const parsed = sendRequestSchema.safeParse(req.body);
    if (!parsed.success) throw new AppError(400, "invalid_payload", parsed.error.message);
    reply.code(201);
    const request = await sendRequest(
      pool,
      registry,
      req.userId!,
      parsed.data.username,
      parsed.data.message ?? null
    );
    return { request };
  });

  app.post("/friend-requests/:id/accept", { preHandler: app.requireAuth }, async (req) => {
    const { id } = req.params as { id: string };
    return acceptRequest(pool, registry, req.userId!, id);
  });

  app.post("/friend-requests/:id/decline", { preHandler: app.requireAuth }, async (req) => {
    const { id } = req.params as { id: string };
    await declineRequest(pool, req.userId!, id);
    return { ok: true };
  });
}
