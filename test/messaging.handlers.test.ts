import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  socketClient,
  emitAck,
  registerUser,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("message:send acks the sender and delivers message:new to the recipient", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const received = new Promise((r) => bobSock.on("message:new", r));
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id,
    body: "hi bob",
    clientMsgId: "c1",
  })) as { id: string; created_at: string; clientMsgId: string };
  expect(ack.id).toBeTruthy();
  expect(ack.clientMsgId).toBe("c1");
  const incoming = (await received) as { message: { body: string; sender_id: string } };
  expect(incoming.message.body).toBe("hi bob");
  expect(incoming.message.sender_id).toBe(alice.id);
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:delivered marks delivered_at and notifies the sender", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice2", "bob2");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  // Register the message:new listener before sending: the fan-out races with
  // the send ack, so attaching it after `emitAck` resolves can drop the event.
  const bobGotNew = new Promise((r) => bobSock.on("message:new", r));
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id, body: "hi", clientMsgId: "c2",
  })) as { id: string };
  // Bob receives then confirms delivery.
  await bobGotNew;
  const deliveredSeen = new Promise((r) => aliceSock.on("message:delivered", r));
  bobSock.emit("message:delivered", { messageId: ack.id });
  const deliv = (await deliveredSeen) as { messageId: string; delivered_at: string };
  expect(deliv.messageId).toBe(ack.id);
  expect(deliv.delivered_at).toBeTruthy();
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:read fans out message:read to the peer with the conversation id", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice3", "bob3");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  // Register the message:new listener before sending (same race as above).
  const bobGotNew = new Promise((r) => bobSock.on("message:new", r));
  const sendAck = (await emitAck(aliceSock, "message:send", {
    toUserId: bob.id, body: "read me", clientMsgId: "c3",
  })) as { id: string };
  await bobGotNew;
  const readSeen = new Promise((r) => aliceSock.on("message:read", r));
  bobSock.emit("message:read", { peerId: alice.id, upToMessageId: sendAck.id });
  const read = (await readSeen) as { conversationId: string; upToMessageId: string };
  expect(read.upToMessageId).toBe(sendAck.id);
  expect(read.conversationId).toBeTruthy();
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("typing:start fans out a typing event to the peer", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice4", "bob4");
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const typingSeen = new Promise((r) => bobSock.on("typing", r));
  aliceSock.emit("typing:start", { toUserId: bob.id });
  const typing = (await typingSeen) as { fromUserId: string; isTyping: boolean };
  expect(typing.fromUserId).toBe(alice.id);
  expect(typing.isTyping).toBe(true);
  aliceSock.disconnect();
  bobSock.disconnect();
});

test("message:send to a non-friend acks an error and does not deliver", async () => {
  const alice = await registerUser(stack.app, "alice5");
  const carol = await registerUser(stack.app, "carol5"); // not friends
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  const carolSock = await socketClient(stack.port, carol.accessToken);
  const carolGotMessage = new Promise((resolve, reject) => {
    carolSock.on("message:new", () => reject(new Error("should not receive")));
    setTimeout(() => resolve(undefined), 200);
  });
  const ack = (await emitAck(aliceSock, "message:send", {
    toUserId: carol.id, body: "hi", clientMsgId: "c4",
  })) as { error: string };
  expect(ack.error).toBe("not_friends");
  await carolGotMessage; // resolves without carol receiving anything
  aliceSock.disconnect();
  carolSock.disconnect();
});
