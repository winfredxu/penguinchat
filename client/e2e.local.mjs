import assert from "node:assert/strict";
import { io } from "socket.io-client";

const baseUrl = process.env.PENGUINCHAT_APP_URL ?? "http://localhost:5173";
const apiUrl = `${baseUrl}/api`;
const suffix = `${Date.now()}`.slice(-9);
const aliceName = `alice_${suffix}`;
const bobName = `bob_${suffix}`;
const password = "noot-noot-123";

async function request(path, options = {}, accessToken) {
  const response = await fetch(`${apiUrl}${path}`, {
    ...options,
    headers: {
      ...(options.body ? { "content-type": "application/json" } : {}),
      ...(accessToken ? { authorization: `Bearer ${accessToken}` } : {}),
      ...options.headers,
    },
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`${options.method ?? "GET"} ${path}: ${response.status} ${JSON.stringify(body)}`);
  return body;
}

async function register(username, displayName) {
  return request("/auth/register", { method: "POST", body: JSON.stringify({ username, display_name: displayName, password }) });
}

async function login(username) {
  return request("/auth/login", { method: "POST", body: JSON.stringify({ username, password }) });
}

function connect(token) {
  return new Promise((resolve, reject) => {
    const socket = io(baseUrl, { auth: { token }, transports: ["websocket"] });
    const timer = setTimeout(() => { socket.disconnect(); reject(new Error("socket connection timed out")); }, 8_000);
    socket.once("connect", () => { clearTimeout(timer); resolve(socket); });
    socket.once("connect_error", reject);
  });
}

await register(aliceName, "Alice E2E");
await register(bobName, "Bob E2E");
const alice = await login(aliceName);
const bob = await login(bobName);
assert.equal(alice.user.username, aliceName);
assert.equal(bob.user.username, bobName);

const sentRequest = await request("/friend-requests", {
  method: "POST",
  body: JSON.stringify({ username: bobName, message: "E2E friend request" }),
}, alice.tokens.accessToken);
const incoming = await request("/friend-requests", {}, bob.tokens.accessToken);
assert.equal(incoming[0].id, sentRequest.request.id);
assert.equal(incoming[0].from_username, aliceName);
await request(`/friend-requests/${sentRequest.request.id}/accept`, { method: "POST" }, bob.tokens.accessToken);

const [aliceContacts, bobContacts] = await Promise.all([
  request("/contacts", {}, alice.tokens.accessToken),
  request("/contacts", {}, bob.tokens.accessToken),
]);
assert.equal(aliceContacts[0].username, bobName);
assert.equal(bobContacts[0].username, aliceName);

const [aliceSocket, bobSocket] = await Promise.all([
  connect(alice.tokens.accessToken),
  connect(bob.tokens.accessToken),
]);
try {
  const text = `Hello from ${aliceName}`;
  const received = new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("message:new timed out")), 8_000);
    bobSocket.once("message:new", ({ message }) => { clearTimeout(timer); resolve(message); });
  });
  const acknowledged = new Promise((resolve, reject) => {
    aliceSocket.timeout(8_000).emit("message:send", {
      toUserId: bob.user.id,
      body: text,
      clientMsgId: crypto.randomUUID(),
    }, (error, ack) => error ? reject(error) : resolve(ack));
  });
  const [message, ack] = await Promise.all([received, acknowledged]);
  assert.equal(message.body, text);
  assert.equal(ack.id, message.id);
  bobSocket.emit("message:delivered", { messageId: message.id });

  const history = await request(`/conversations/${alice.user.id}/messages?limit=10`, {}, bob.tokens.accessToken);
  assert.equal(history.messages[0].body, text);
  console.log(JSON.stringify({ ok: true, users: [aliceName, bobName], messageId: message.id }));
} finally {
  aliceSocket.disconnect();
  bobSocket.disconnect();
}
