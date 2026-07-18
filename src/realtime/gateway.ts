import type { Server } from "socket.io";
import { Server as IoServer } from "socket.io";
import { createAdapter } from "@socket.io/redis-adapter";
import type { Server as HttpServer } from "node:http";
import type { Config } from "../config.js";
import type { RedisClientType } from "redis";
import { verifyAccess } from "../modules/auth/tokens.js";

export interface GatewayDeps {
  config: Config;
  pub: RedisClientType;
  sub: RedisClientType;
}

export function createGateway(server: HttpServer, deps: GatewayDeps): Server {
  const io = new IoServer(server, { cors: { origin: "*" } });
  io.adapter(createAdapter(deps.pub, deps.sub));

  io.use((socket, next) => {
    const token = socket.handshake.auth?.token;
    if (!token || typeof token !== "string") {
      return next(new Error("unauthorized"));
    }
    try {
      const { sub } = verifyAccess(token, deps.config);
      socket.data.userId = sub;
      next();
    } catch {
      return next(new Error("unauthorized"));
    }
  });

  io.on("connection", (socket) => {
    socket.join(socket.data.userId as string);
  });

  return io;
}
