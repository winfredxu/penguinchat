import { afterAll, expect, test } from "vitest";
import { makeRealtimeStack, socketClient, type RealtimeStack } from "./helpers/realtime.js";
import { makeFriends } from "./helpers/friends.js";

let stack: RealtimeStack;
afterAll(async () => { if (stack) await stack.cleanup(); });

test("GET /contacts reflects a friend's real online presence", async () => {
  stack = await makeRealtimeStack();
  const { a: alice, b: bob } = await makeFriends(stack.app, "alice", "bob");
  // Bob offline initially.
  let res = await stack.app.inject({
    method: "GET", url: "/contacts",
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.json().find((c: any) => c.username === "bob").presence).toBe("offline");
  // Bob comes online.
  const bobSock = await socketClient(stack.port, bob.accessToken);
  await new Promise((r) => setTimeout(r, 100)); // let the online broadcast settle in Redis
  res = await stack.app.inject({
    method: "GET", url: "/contacts",
    headers: { authorization: `Bearer ${alice.accessToken}` },
  });
  expect(res.json().find((c: any) => c.username === "bob").presence).toBe("online");
  bobSock.disconnect();
});
