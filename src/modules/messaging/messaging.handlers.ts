import type { Server, Socket } from "socket.io";
import type { Pool } from "pg";
import { AppError } from "../../lib/errors.js";
import type { SessionRegistry } from "../session-registry/session-registry.js";
import { findById } from "./messaging.repo.js";
import { markDelivered, markRead, send } from "./messaging.service.js";

export interface MessagingHandlerDeps {
  pool: Pool;
  registry: SessionRegistry;
}

export function registerMessagingHandlers(io: Server, deps: MessagingHandlerDeps): void {
  const { pool, registry } = deps;

  // Socket.IO does not await async listeners; route fire-and-forget handlers
  // through safe() so failures are logged rather than becoming unhandled rejections.
  const safe = (fn: () => Promise<void>): void => {
    fn().catch((err) => {
      // eslint-disable-next-line no-console
      console.error("messaging handler error:", err);
    });
  };

  io.on("connection", (socket: Socket) => {
    const userId = socket.data.userId as string;

    socket.on("message:send", (payload: { toUserId: string; body: string; clientMsgId: string }, ack: (r: unknown) => void) => {
      (async () => {
        try {
          const message = await send(pool, userId, { toUserId: payload.toUserId, body: payload.body });
          await registry.notify(payload.toUserId, "message:new", { message });
          ack({ id: message.id, created_at: message.created_at, clientMsgId: payload.clientMsgId });
        } catch (err) {
          ack({ error: err instanceof AppError ? err.code : "internal" });
        }
      })();
    });

    socket.on("message:delivered", (payload: { messageId: string }) => {
      safe(async () => {
        const message = await findById(pool, payload.messageId);
        if (!message) return;
        // Only the message's recipient can confirm delivery.
        if (message.recipient_id !== userId) return;
        const updated = await markDelivered(pool, payload.messageId);
        if (!updated || !updated.delivered_at) return;
        await registry.notify(message.sender_id, "message:delivered", {
          messageId: payload.messageId,
          delivered_at: updated.delivered_at,
        });
      });
    });

    socket.on("message:read", (payload: { peerId: string; upToMessageId: string }) => {
      safe(async () => {
        const result = await markRead(pool, userId, payload.peerId, payload.upToMessageId);
        await registry.notify(payload.peerId, "message:read", {
          conversationId: result.conversation,
          upToMessageId: payload.upToMessageId,
        });
      });
    });

    const onTyping = (isTyping: boolean) => (payload: { toUserId: string }) => {
      safe(async () => {
        await registry.notify(payload.toUserId, "typing", { fromUserId: userId, isTyping });
      });
    };
    socket.on("typing:start", onTyping(true));
    socket.on("typing:stop", onTyping(false));
  });
}
