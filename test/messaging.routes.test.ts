import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  registerUser,
  emitAck,
  socketClient,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => {
  if (stack) await stack.cleanup();
});

async function sendViaSocket(token: string, toUserId: string, body: string) {
  const sock = await socketClient(stack.port, token);
  const msg = (await emitAck(sock, "message:send", {
    toUserId,
    body,
    clientMsgId: body,
  })) as { id: string };
  sock.disconnect();
  return msg;
}

test("GET /conversations/:peerId/messages returns messages newest-first", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  for (let i = 0; i < 3; i++) {
    await sendViaSocket(alice.accessToken, bob.id, `m${i}`);
    await new Promise((r) => setTimeout(r, 10));
  }
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=50`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(200);
  expect(res.json().messages.map((m: any) => m.body)).toEqual(["m2", "m1", "m0"]);
});

test("paginates with the before cursor", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice2", "bob2");
  for (let i = 0; i < 3; i++) {
    await sendViaSocket(alice.accessToken, bob.id, `m${i}`);
    await new Promise((r) => setTimeout(r, 10));
  }
  const page1 = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  const p1 = page1.json().messages;
  const page2 = await stack.app.inject({
    method: "GET",
    url: `/conversations/${bob.id}/messages?limit=2&before=${encodeURIComponent(p1[1].created_at)}`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(page2.json().messages.map((m: any) => m.body)).toEqual(["m0"]);
});

test("to a non-friend returns 403", async () => {
  stack = await makeRealtimeStack();
  const alice = await registerUser(stack.app, "alice3");
  const carol = await registerUser(stack.app, "carol3");
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/${carol.id}/messages`,
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.statusCode).toBe(403);
  expect(res.json().error).toBe("not_friends");
});

test("without auth returns 401", async () => {
  stack = await makeRealtimeStack();
  const res = await stack.app.inject({
    method: "GET",
    url: `/conversations/00000000-0000-0000-0000-000000000000/messages`,
  });
  expect(res.statusCode).toBe(401);
});
