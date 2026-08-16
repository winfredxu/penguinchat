import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { io } from "socket.io-client";

const apiUrl = (process.env.PENGUINCHAT_API_URL ?? "http://127.0.0.1:3100").replace(/\/$/, "");
const timeoutMs = Number(process.env.PENGUINCHAT_ACCEPTANCE_TIMEOUT_MS ?? 8_000);
const suffix = `${Date.now()}_${process.pid}`.slice(-18);
const password = `Noot-${randomUUID()}`;
const aliceName = `accept_alice_${suffix}`.slice(0, 32);
const bobName = `accept_bob_${suffix}`.slice(0, 32);
const sockets = new Set();

const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function request(path, options = {}, accessToken) {
  const response = await fetch(`${apiUrl}${path}`, {
    ...options,
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
      ...options.headers,
    },
  });
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    throw new Error(`${options.method ?? "GET"} ${path}: ${response.status} ${text}`);
  }
  return body;
}

function eventOnce(socket, event, predicate = () => true) {
  return new Promise((resolve, reject) => {
    const handler = (payload) => {
      if (!predicate(payload)) return;
      clearTimeout(timer);
      socket.off(event, handler);
      resolve(payload);
    };
    const timer = setTimeout(() => {
      socket.off(event, handler);
      reject(new Error(`${event} timed out after ${timeoutMs} ms`));
    }, timeoutMs);
    socket.on(event, handler);
  });
}

function connect(accessToken) {
  return new Promise((resolve, reject) => {
    const socket = io(apiUrl, {
      auth: { token: accessToken },
      reconnection: false,
      transports: ["websocket"],
    });
    const timer = setTimeout(() => {
      socket.disconnect();
      reject(new Error(`Socket.IO connection timed out after ${timeoutMs} ms`));
    }, timeoutMs);
    socket.once("connect", () => {
      clearTimeout(timer);
      sockets.add(socket);
      resolve(socket);
    });
    socket.once("connect_error", (error) => {
      clearTimeout(timer);
      socket.disconnect();
      reject(error);
    });
  });
}

function send(socket, payload) {
  return new Promise((resolve, reject) => {
    socket.timeout(timeoutMs).emit("message:send", payload, (error, acknowledgement) => {
      if (error) return reject(error);
      if (acknowledgement?.error) return reject(new Error(`message:send: ${acknowledgement.error}`));
      resolve(acknowledgement);
    });
  });
}

async function expectContact(token, userId, presence) {
  const contacts = await request("/contacts", {}, token);
  const contact = contacts.find((candidate) => candidate.id === userId);
  assert.ok(contact, `contact ${userId} is missing`);
  assert.equal(contact.presence, presence);
}

async function exchange({ sender, senderUser, recipient, recipientUser, body, clientMsgId }) {
  const liveEvents = [];
  const collect = (event) => {
    if (event.message?.client_msg_id === clientMsgId) liveEvents.push(event);
  };
  recipient.on("message:new", collect);
  const received = eventOnce(
    recipient,
    "message:new",
    (event) => event.message?.client_msg_id === clientMsgId
  );
  const payload = { toUserId: recipientUser.id, body, clientMsgId };
  const acknowledgement = await send(sender, payload);
  const incoming = await received;
  assert.equal(incoming.message.sender_id, senderUser.id);
  assert.equal(incoming.message.recipient_id, recipientUser.id);
  assert.equal(incoming.message.body, body);
  assert.equal(incoming.message.id, acknowledgement.id);

  const retry = await send(sender, payload);
  assert.equal(retry.id, acknowledgement.id, "retry created a second server message");
  await delay(150);
  assert.equal(liveEvents.length, 1, "retry emitted a duplicate message:new event");
  recipient.off("message:new", collect);

  const delivered = eventOnce(sender, "message:delivered", (event) => event.messageId === acknowledgement.id);
  recipient.emit("message:delivered", { messageId: acknowledgement.id });
  assert.ok((await delivered).delivered_at);

  const read = eventOnce(sender, "message:read", (event) => event.upToMessageId === acknowledgement.id);
  recipient.emit("message:read", { peerId: senderUser.id, upToMessageId: acknowledgement.id });
  assert.equal((await read).upToMessageId, acknowledgement.id);
  return acknowledgement.id;
}

try {
  await request("/health");

  const aliceRegistration = await request("/auth/register", {
    method: "POST",
    body: JSON.stringify({ username: aliceName, display_name: "Alice Acceptance", password }),
  });
  const bobRegistration = await request("/auth/register", {
    method: "POST",
    body: JSON.stringify({ username: bobName, display_name: "Bob Acceptance", password }),
  });
  const alice = await request("/auth/login", {
    method: "POST",
    body: JSON.stringify({ username: aliceName, password }),
  });
  const bob = await request("/auth/login", {
    method: "POST",
    body: JSON.stringify({ username: bobName, password }),
  });
  assert.equal(alice.user.id, aliceRegistration.user.id);
  assert.equal(bob.user.id, bobRegistration.user.id);

  const friendRequest = await request("/friend-requests", {
    method: "POST",
    body: JSON.stringify({ username: bobName, message: "Two-user acceptance" }),
  }, alice.tokens.accessToken);
  const incomingRequests = await request("/friend-requests", {}, bob.tokens.accessToken);
  assert.ok(incomingRequests.some((item) => item.id === friendRequest.request.id));
  await request(`/friend-requests/${friendRequest.request.id}/accept`, { method: "POST" }, bob.tokens.accessToken);
  await expectContact(alice.tokens.accessToken, bob.user.id, "offline");
  await expectContact(bob.tokens.accessToken, alice.user.id, "offline");

  let aliceSocket = await connect(alice.tokens.accessToken);
  const aliceSeesBobOnline = eventOnce(
    aliceSocket,
    "presence:update",
    (event) => event.userId === bob.user.id && event.status === "online"
  );
  const bobSocket = await connect(bob.tokens.accessToken);
  await aliceSeesBobOnline;
  await expectContact(bob.tokens.accessToken, alice.user.id, "online");

  const typingStarted = eventOnce(
    bobSocket,
    "typing",
    (event) => event.fromUserId === alice.user.id && event.isTyping === true
  );
  aliceSocket.emit("typing:start", { toUserId: bob.user.id });
  await typingStarted;
  const typingStopped = eventOnce(
    bobSocket,
    "typing",
    (event) => event.fromUserId === alice.user.id && event.isTyping === false
  );
  aliceSocket.emit("typing:stop", { toUserId: bob.user.id });
  await typingStopped;

  const aliceMessageId = await exchange({
    sender: aliceSocket,
    senderUser: alice.user,
    recipient: bobSocket,
    recipientUser: bob.user,
    body: `hello from ${aliceName}`,
    clientMsgId: randomUUID(),
  });
  const bobMessageId = await exchange({
    sender: bobSocket,
    senderUser: bob.user,
    recipient: aliceSocket,
    recipientUser: alice.user,
    body: `hello from ${bobName}`,
    clientMsgId: randomUUID(),
  });

  const bobSeesAliceOffline = eventOnce(
    bobSocket,
    "presence:update",
    (event) => event.userId === alice.user.id && event.status === "offline"
  );
  aliceSocket.disconnect();
  sockets.delete(aliceSocket);
  await bobSeesAliceOffline;
  await expectContact(bob.tokens.accessToken, alice.user.id, "offline");

  const bobSeesAliceReconnect = eventOnce(
    bobSocket,
    "presence:update",
    (event) => event.userId === alice.user.id && event.status === "online"
  );
  aliceSocket = await connect(alice.tokens.accessToken);
  await bobSeesAliceReconnect;

  const [aliceHistory, bobHistory] = await Promise.all([
    request(`/conversations/${bob.user.id}/messages?limit=100`, {}, alice.tokens.accessToken),
    request(`/conversations/${alice.user.id}/messages?limit=100`, {}, bob.tokens.accessToken),
  ]);
  const aliceIds = aliceHistory.messages.map((message) => message.id);
  const bobIds = bobHistory.messages.map((message) => message.id);
  assert.deepEqual(aliceIds, bobIds, "users did not converge on the same history");
  assert.equal(new Set(aliceIds).size, 2, "history contains a duplicate message");
  assert.deepEqual(new Set(aliceIds), new Set([aliceMessageId, bobMessageId]));
  for (const message of aliceHistory.messages) {
    assert.ok(message.delivered_at, `${message.id} is not delivered`);
    assert.ok(message.read_at, `${message.id} is not read`);
  }

  console.log(JSON.stringify({
    ok: true,
    apiUrl,
    users: [aliceName, bobName],
    messageIds: aliceIds,
    checks: [
      "register_login",
      "friend_request_accept",
      "initial_presence",
      "bidirectional_messages",
      "typing_start_stop",
      "delivered_read",
      "disconnect_reconnect_presence",
      "history_convergence",
      "retry_duplicate_suppression",
    ],
  }, null, 2));
} finally {
  for (const socket of sockets) socket.disconnect();
}
