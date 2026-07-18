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

  io.on("connection", (socket: Socket) => {
    const userId = socket.data.userId as string;
    socket.join(userId);

    void (async () => {
      await presence.setOnline(userId);
      const friends = await friendIds(pool, userId);
      for (const fid of friends) {
        io.to(fid).emit("presence:update", { userId, status: "online" });
      }
    })();

    socket.on("presence:heartbeat", () => {
      void presence.refresh(userId);
    });

    socket.on("disconnect", () => {
      void (async () => {
        const remaining = await io.in(userId).fetchSockets();
        if (remaining.length > 0) return; // another device still online
        await presence.clear(userId);
        const friends = await friendIds(pool, userId);
        for (const fid of friends) {
          io.to(fid).emit("presence:update", { userId, status: "offline" });
        }
      })();
    });
  });
}
