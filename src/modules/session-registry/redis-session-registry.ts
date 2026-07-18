import type { Server } from "socket.io";
import type { SessionRegistry } from "./session-registry.js";

/**
 * Redis-backed session registry. Emits to the user's room via the Socket.IO
 * server; the @socket.io/redis-adapter (installed on `io` by the gateway) fans
 * the emit out across all instances and all of the user's devices.
 *
 * `io` is attached lazily because the Socket.IO server is not created until
 * after app.listen() (it needs the raw HTTP server). Before attach, notify is
 * a silent no-op — identical to Plan 1's NoopSessionRegistry. No request can
 * arrive before listen() returns, so this window is harmless.
 */
export class RedisSessionRegistry implements SessionRegistry {
  private io: Server | null = null;

  attach(io: Server): void {
    this.io = io;
  }

  async notify(userId: string, event: string, payload: unknown): Promise<void> {
    if (!this.io) return;
    this.io.to(userId).emit(event, payload);
  }
}
