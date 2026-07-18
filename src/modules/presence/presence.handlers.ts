import type { Server, Socket } from "socket.io";
import type { Pool } from "pg";
import { listFriends } from "../contacts/contacts.repo.js";
import type { PresenceService } from "./presence.service.js";

export interface PresenceHandlerDeps {
  presence: PresenceService;
  pool: Pool;
}

async function friendIds(pool: Pool, userId: string): Promise<string[]> {
  const friends = await listFriends(pool, userId);
  return friends.map((f) => f.id);
}

export function registerPresenceHandlers(io: Server, deps: PresenceHandlerDeps): void {
  const { presence, pool } = deps;

  // Socket.IO does not await async event listeners, so a rejected promise inside
  // a listener becomes an unhandled rejection. Each handler wraps its async work
  // in an IIFE with a .catch so failures (postgres/redis flap) are logged rather
  // than silently dropped.
  const safe = (fn: () => Promise<void>): void => {
    fn().catch((err) => {
      // Structured logging lands with FU-6; until then, surface to stderr.
      // eslint-disable-next-line no-console
      console.error("presence handler error:", err);
    });
  };

  io.on("connection", (socket: Socket) => {
    const userId = socket.data.userId as string;
    socket.join(userId);

    safe(async () => {
      await presence.setOnline(userId);
      const friends = await friendIds(pool, userId);
      for (const fid of friends) {
        io.to(fid).emit("presence:update", { userId, status: "online" });
      }
    });

    socket.on("presence:heartbeat", () => {
      // Fire-and-forget is fine here: a silent failure just leaves a stale TTL,
      // which self-heals on the next beat or on disconnect.
      void presence.refresh(userId);
    });

    socket.on("disconnect", () => {
      safe(async () => {
        const remaining = await io.in(userId).fetchSockets();
        if (remaining.length > 0) return; // another device still online
        await presence.clear(userId);
        const friends = await friendIds(pool, userId);
        for (const fid of friends) {
          io.to(fid).emit("presence:update", { userId, status: "offline" });
        }
      });
    });
  });
}
