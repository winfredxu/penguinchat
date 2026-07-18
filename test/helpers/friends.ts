import type { FastifyInstance } from "fastify";
import { registerUser } from "./realtime.js";

export interface RegisteredUser {
  id: string;
  accessToken: string;
  username: string;
}

export async function makeFriends(
  app: FastifyInstance,
  aUsername: string,
  bUsername: string
): Promise<{ a: RegisteredUser; b: RegisteredUser }> {
  const a = await registerUser(app, aUsername);
  const b = await registerUser(app, bUsername);
  const send = await app.inject({
    method: "POST",
    url: "/friend-requests",
    headers: { authorization: `Bearer ${a.accessToken}` },
    payload: { username: b.username },
  });
  const requestId = send.json().request.id;
  await app.inject({
    method: "POST",
    url: `/friend-requests/${requestId}/accept`,
    headers: { authorization: `Bearer ${b.accessToken}` },
  });
  return { a, b };
}
