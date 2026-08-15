# Native macOS API contract audit

Audited against the merged server/Web implementation on `main` (`ad2ca80`). Local REST
and Socket.IO share one origin: `http://127.0.0.1:3000` when running the Node
server directly. Docker exposes it on host port `3100` by default.

## Common behavior

- Protected REST endpoints use `Authorization: Bearer <accessToken>`.
- JSON errors are `{ "error": String, "message": String }`. Known codes include
  `invalid_payload`, `invalid_credentials`, `invalid_token`, `unauthorized`,
  `username_taken`, `not_found`, `self_request`, `already_friends`,
  `request_exists`, `forbidden`, `not_friends`, `invalid_request`, and
  `internal`.
- The server applies a global limit of 100 HTTP requests per minute.
- User and message timestamps are ISO-8601 strings. IDs are UUID strings.
- Access tokens default to 15 minutes. Refresh tokens default to 30 days and
  rotate on every refresh. Reusing a rotated token revokes all refresh tokens
  for that user. There is currently no logout/revoke endpoint.

## REST

| Method and path | Request | Success response |
| --- | --- | --- |
| `GET /health` | — | `{ "status": "ok" }` |
| `POST /auth/register` | `{ username, display_name, password }` | `201`, `{ user, tokens }` |
| `POST /auth/login` | `{ username, password }` | `{ user, tokens }` |
| `POST /auth/refresh` | `{ refreshToken }` | `{ tokens }` |
| `GET /me` | bearer | `{ user }` |
| `PATCH /me` | bearer, any of `{ display_name, signature, avatar_url }` | `{ user }` |
| `GET /contacts` | bearer | `Contact[]` |
| `GET /friend-requests` | bearer | incoming pending `FriendRequest[]` |
| `POST /friend-requests` | bearer, `{ username, message? }` | `201`, `{ request }` |
| `POST /friend-requests/:id/accept` | bearer | `{ friendId }` |
| `POST /friend-requests/:id/decline` | bearer | `{ ok: true }` |
| `GET /conversations/:peerId/messages` | bearer; `before` ISO timestamp and `limit` query params | `{ messages }` newest-first |

`limit` defaults to 50 and is clamped to 1...100. The client must reverse a
page before chronological display. History is only available between friends.

### Shapes

```text
User = {
  id, username, display_name, avatar_url: string|null,
  signature: string|null, created_at
}
Contact = User + { presence: "online"|"offline" }
FriendRequest = {
  id, from_user, to_user, message: string|null,
  status, created_at, from_username?, from_display_name?
}
Message = {
  id, conversation, sender_id, recipient_id, body, created_at,
  delivered_at: string|null, read_at: string|null
}
tokens = { accessToken, refreshToken }
```

The shared TypeScript type still permits `away`, but the current presence
service only produces `online` or `offline`. The Swift model accepts all three
to remain forward-compatible.

## Socket.IO

Connect on the API origin using the default `/socket.io` path and handshake
auth `{ token: accessToken }`. A missing, invalid, expired, or subject-less
access token fails with `unauthorized`. Socket.IO handles transport negotiation
and reconnect; reconnect after token refresh must update handshake auth first.

Client-to-server events:

| Event | Payload / acknowledgement |
| --- | --- |
| `presence:heartbeat` | no payload; send about every 25 seconds (server TTL is 30 seconds) |
| `message:send` | `{ toUserId, body, clientMsgId }`; ack `{ id, created_at, clientMsgId }` or `{ error }` |
| `message:delivered` | `{ messageId }` |
| `message:read` | `{ peerId, upToMessageId }` |
| `typing:start`, `typing:stop` | `{ toUserId }` |

Server-to-client events:

| Event | Payload |
| --- | --- |
| `presence:update` | `{ userId, status: "online"|"offline" }` |
| `friend:request` | `{ request }` |
| `friend:accepted` | `{ friendId }` |
| `message:new` | `{ message }` |
| `message:delivered` | `{ messageId, delivered_at }` |
| `message:read` | `{ conversationId, upToMessageId }` |
| `typing` | `{ fromUserId, isTyping }` |

Important implementation details for later stages:

- `clientMsgId` is echoed in the send acknowledgement but is not persisted in
  the server message row; use it only to reconcile optimistic local messages.
- Receipt and typing events have no acknowledgement. `message:send` is rejected
  with `not_friends` when applicable.
- A received `message:new` should trigger `message:delivered`; the visible
  conversation should also emit `message:read` at its latest received message.
- The active read input is `peerId`, not the older design document's
  `conversationId`. The server derives the conversation ID from both users.
- The current socket handler does not validate message length or empty content;
  the native client should trim/disable empty sends while server validation is
  hardened separately.
