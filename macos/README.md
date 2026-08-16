# PenguinChat for macOS

This directory contains the native SwiftUI/AppKit client bootstrap. It does not
use a `WKWebView` or embed the React client.

## Requirements and dependency policy

- macOS 14 Sonoma or newer.
- Xcode 16 or newer with Swift 6; the bootstrap was verified with Xcode 26.6.
- Swift Package Manager is the only package manager.
- Stage 1 uses Apple frameworks only (`SwiftUI`, `Foundation`). The future
  Socket.IO adapter must live behind a `RealtimeTransport` protocol and be
  pinned to an exact compatible release of `socket.io-client-swift`; UI and
  domain code must not import the package directly.

The package separates `PenguinChatCore` (configuration, models, HTTP transport,
services, Keychain token storage, and session lifecycle) from the
`PenguinChatMac` SwiftUI executable. This keeps authentication and network
behavior testable without launching the app. Sensitive access and refresh
tokens are stored only as a generic-password Keychain item; they are never
written to `UserDefaults` or logs.

## Build, test, and run

Start the API on port 3000, then run:

```bash
cd macos/PenguinChatMac
swift test
swift build
swift run PenguinChatMac
```

You can also open `macos/PenguinChatMac/Package.swift` in Xcode, select the
`PenguinChatMac` scheme, and Run. The app provides native login and registration,
restores a Keychain-backed session on launch, rotates an expired access/refresh
pair once, and removes the local credentials on logout. The current server has
no revoke endpoint, so logout is intentionally local-only.

Debug uses `http://127.0.0.1:3000` for both REST and Socket.IO. Override it in
the Xcode scheme or shell:

```bash
PENGUINCHAT_API_URL=http://127.0.0.1:3100 swift run PenguinChatMac
```

Only `http` and `https` origins with a host are accepted; invalid overrides
fall back to the local endpoint. API and event details are recorded in
`docs/macos-api-contract.md`.

## Two-user acceptance run

`macos/scripts/run-acceptance.sh` drives two complete client stacks — the same
`SessionManager` / `RealtimeChatStore` / `ChatViewModel` the SwiftUI app builds,
over the real Socket.IO transport — against a live server, and asserts the
end-to-end chat criteria.

Start the dependencies and API first, then run it:

```bash
docker compose up -d api
macos/scripts/run-acceptance.sh                     # defaults to :3100
PENGUINCHAT_API_URL=http://127.0.0.1:3000 macos/scripts/run-acceptance.sh
```

It prints one `PASS`/`FAIL` line per check and exits non-zero if any fail. The
script aborts early with instructions when no healthy server answers `/health`.

Covered: registration and login prerequisites, session restore, friend request
send/accept, initial presence from both the live event and the REST snapshot,
bidirectional messages, send acknowledgement, delivery and read receipts,
unread counts, typing start/stop, forced disconnect, offline send, reconnect
history convergence, duplicate suppression, ordering, and history pagination
(`limit` plus the `before` cursor).

Each run registers fresh throwaway users, so it is repeatable against the same
database without cleanup. Their tokens are held in memory only — the harness
never touches the app's Keychain item and writes no credentials to disk.
