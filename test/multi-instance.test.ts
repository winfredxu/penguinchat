import { afterEach, beforeEach, expect, test } from "vitest";
import {
  makeMultiInstanceStack,
  socketClient,
  emitAck,
  type MultiInstanceStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: MultiInstanceStack;
beforeEach(async () => {
  stack = await makeMultiInstanceStack();
});
afterEach(async () => {
  if (stack) await stack.cleanup();
});

// These tests prove the cross-instance fan-out path (FU-12): an event emitted
// on instance A via `registry.notify(userId, ...)` -> `io.to(userId).emit(...)`
// is delivered to a socket connected to instance B, through the
// @socket.io/redis-adapter. This is the load-bearing path for every Plan 2b
// messaging event and for presence broadcasts.

test("message:new fans out cross-instance: sender on A, recipient on B", async () => {
  const [portA, portB] = stack.ports;
  const { a: alice, b: bob } = await makeFriends(stack.apps[0], "alice", "bob");
  const aliceSock = await socketClient(portA, alice.accessToken);
  const bobSock = await socketClient(portB, bob.accessToken);

  const received = new Promise((r) => bobSock.on("message:new", r));
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id,
    body: "cross-instance",
    clientMsgId: "c1",
  })) as { id: string };
  expect(ack.id).toBeTruthy();

  const incoming = (await received) as { message: { body: string; sender_id: string } };
  expect(incoming.message.body).toBe("cross-instance");
  expect(incoming.message.sender_id).toBe(alice.id);

  aliceSock.disconnect();
  bobSock.disconnect();
}, 30000);

test("presence:update fans out cross-instance: connect on A, friend on B sees online", async () => {
  const [portA, portB] = stack.ports;
  const { a: alice, b: bob } = await makeFriends(stack.apps[0], "alice2", "bob2");
  const bobSock = await socketClient(portB, bob.accessToken);
  const seen = new Promise((r) =>
    bobSock.on("presence:update", (p: { userId: string; status: string }) => {
      if (p.userId === alice.id && p.status === "online") r(p);
    })
  );
  // Alice connecting on instance A must fan presence:update to Bob on instance B.
  const aliceSock = await socketClient(portA, alice.accessToken);
  const update = (await seen) as { userId: string; status: string };
  expect(update.userId).toBe(alice.id);
  expect(update.status).toBe("online");

  aliceSock.disconnect();
  bobSock.disconnect();
}, 30000);

test("typing and message:delivered fan out cross-instance", async () => {
  const [portA, portB] = stack.ports;
  const { a: alice, b: bob } = await makeFriends(stack.apps[0], "alice3", "bob3");
  const aliceSock = await socketClient(portA, alice.accessToken);
  const bobSock = await socketClient(portB, bob.accessToken);

  // Attach every listener BEFORE any emit so an event delivered faster than
  // the await chain can't slip past an un-attached listener.
  const typingSeen = new Promise((r) => bobSock.on("typing", r));
  const bobGotMessage = new Promise((r) => bobSock.on("message:new", r));
  const deliveredSeen = new Promise((r) => aliceSock.on("message:delivered", r));

  // typing:start from Alice (A) -> Bob (B). Plain emit: the handler is
  // fire-and-forget and does not ack.
  aliceSock.emit("typing:start", { toUserId: bob.id });
  const typing = (await typingSeen) as { fromUserId: string; isTyping: boolean };
  expect(typing.fromUserId).toBe(alice.id);
  expect(typing.isTyping).toBe(true);

  // delivered: Alice (A) sends -> Bob (B) receives -> Bob emits delivered ->
  // Alice (A) sees message:delivered
  const sendAck = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id,
    body: "hi",
    clientMsgId: "c2",
  })) as { id: string };
  await bobGotMessage;
  bobSock.emit("message:delivered", { messageId: sendAck.id });
  const deliv = (await deliveredSeen) as { messageId: string; delivered_at: string };
  expect(deliv.messageId).toBe(sendAck.id);
  expect(deliv.delivered_at).toBeTruthy();

  aliceSock.disconnect();
  bobSock.disconnect();
}, 20000);
