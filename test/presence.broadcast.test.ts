import { afterAll, expect, test } from "vitest";
import {
  makeRealtimeStack,
  socketClient,
  type RealtimeStack,
} from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => {
  if (stack) await stack.cleanup();
});

test("connecting broadcasts presence:update online to a friend", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const seen = new Promise<{ userId: string; status: string }>((r) =>
    bobSock.on("presence:update", r)
  );
  await socketClient(stack.port, alice.accessToken);
  const msg = await seen;
  expect(msg.userId).toBe(alice.id);
  expect(msg.status).toBe("online");
  bobSock.disconnect();
});

test("last disconnect broadcasts presence:update offline to a friend", async () => {
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice2", "bob2");
  const bobSock = await socketClient(stack.port, bob.accessToken);
  const aliceSock = await socketClient(stack.port, alice.accessToken);
  let last: { userId: string; status: string } | undefined;
  bobSock.on("presence:update", (m: { userId: string; status: string }) => {
    last = m;
  });
  aliceSock.disconnect();
  const offline = await new Promise<{ userId: string; status: string }>((resolve) => {
    const t = setInterval(() => {
      if (last && last.status === "offline") {
        clearInterval(t);
        resolve(last);
      }
    }, 50);
  });
  expect(offline.userId).toBe(alice.id);
  expect(offline.status).toBe("offline");
  bobSock.disconnect();
});
