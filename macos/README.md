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

## Window, menus, and keyboard shortcuts

The app is a single `Window` scene, not a `WindowGroup`: one signed-in session
per launch, because a second window would open a second realtime connection for
the same account. Minimum content size is 840×560, default 1040×680.

| Menu | Command | Shortcut |
| --- | --- | --- |
| 文件 | 添加好友 | ⇧⌘N |
| 会话 | 聚焦输入框 | ⌘L |
| 会话 | 下一个会话 | ⇧⌘] |
| 会话 | 上一个会话 | ⇧⌘[ |
| 会话 | 刷新 | ⌘R |
| 会话 | 重新连接 | ⇧⌘R |
| 显示 | 消息 / 联系人 / 好友请求 | ⌘1 / ⌘2 / ⌘3 |

Menu items are disabled when they do not apply — everything except the sidebar
switches requires a signed-in session, and 聚焦输入框 additionally requires a
selected conversation. Menu commands reach the view through a one-way Combine
command bus rather than shared mutable state, so the shell only observes them
while it exists.

Conversation switching wraps around the list. Empty states use
`ContentUnavailableView`. Sidebar rows, the toolbar, message bubbles, and the
composer carry explicit accessibility labels; bubbles and conversation rows are
single accessibility elements with a composed description (sender, text, time,
unread count) instead of a pile of unlabeled children.

## Notifications, Dock badge, and offline recovery

`NotificationPlanner` in `PenguinChatCore` holds the rules, free of AppKit so it
is unit-testable: the first conversation projection after launch or login is
treated as history and never notifies; a message is notified once and only once;
a message in the thread you are currently reading is suppressed while the app is
active, and stays suppressed after the window loses focus. The Dock badge shows
the unread total, clamped to `99+`.

`NotificationCoordinator` owns the AppKit side. It requests notification
authorization after sign-in, groups banners per peer by `threadIdentifier`, uses
the server message id as the notification identifier, clears delivered banners
when you open a thread or the app becomes active, and opens the right
conversation when you click one. `UNUserNotificationCenter.current()` traps in a
process with no bundle identifier, so the coordinator only obtains a center when
running from a real `.app` bundle — `swift run` keeps working, with the Dock
badge still live.

When the realtime connection drops past its own backoff (`disconnected`,
`failed`, `authenticationFailed`), the sidebar footer shows a 重新连接 link and
⇧⌘R becomes available. `RealtimeChatStore.reconnect()` refreshes the access
token if needed and re-subscribes the event stream before re-dialing, which is
what makes recovery work after a full `stop()`.

Failure reasons that reach the UI or `OSLog` pass through `Redaction` first:
bearer headers, bare JWTs, and keyed `token` / `refreshToken` / `password` /
`jti` fields are replaced, and known error types are described structurally
(`server(401/invalid_token)`, `ack_timeout`) rather than dumped.

## Packaging a local `.app`

```bash
macos/scripts/package-app.sh                 # Release, ad-hoc signed
CONFIGURATION=debug macos/scripts/package-app.sh
SIGN_IDENTITY="Developer ID Application: …" macos/scripts/package-app.sh
open macos/build/PenguinChat.app
```

The script builds `--product PenguinChatMac`, assembles
`macos/build/PenguinChat.app`, copies `packaging/Info.plist` and
`packaging/AppIcon.icns`, signs, and finishes with
`codesign --verify --deep --strict`.

Signing notes:

- The default identity is `-` (ad-hoc), which is enough to launch locally.
  Entitlements are deliberately *not* passed in that case:
  `keychain-access-groups` contains `$(AppIdentifierPrefix)`, which has nothing
  to substitute without a Team ID. The local build is unsandboxed and does not
  need the group.
- With a Developer ID identity the script adds `--options runtime --timestamp
  --entitlements packaging/PenguinChatMac.entitlements`. That build is what you
  would submit to `notarytool`; notarization is not wired into the script.
- `packaging/Info.plist` declares `com.penguinchat.macos`, requires macOS 14,
  and exempts only localhost from ATS via `NSAllowsLocalNetworking`. Any other
  host still has to be `https`.
- Regenerate the icon with `swift macos/packaging/make-icon.swift`; it renders
  every required size in code and runs `iconutil`, so no binary asset is checked
  in beyond the resulting `.icns`.

## Two-user acceptance runs

### Native client harness

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

Also covered: Keychain restart-restore (a second `KeychainTokenStore` instance
over the same service stands in for a new process, then `logout()` is asserted to
remove the item), offline detection plus manual `reconnect()`, the
notification/badge path over the live projection, and the redaction rules.

Each run registers fresh throwaway users, so it is repeatable against the same
database without cleanup. Their tokens are held in memory only — the harness
never touches the app's Keychain item and writes no credentials to disk. The
restart-restore section uses a per-run QA service name
(`com.penguinchat.macos.acceptance.<uuid>`) and deletes the item afterwards, so
the shipping app's session is never disturbed.

### Server-contract harness

The repository includes a credential-free harness that exercises the same REST
and Socket.IO contract as two native clients. It creates uniquely named users,
so it is safe to rerun against a local development database. From the repository
root:

```bash
npm ci
docker compose up -d --build postgres redis api
npm run acceptance:two-user
```

The API is expected at `http://127.0.0.1:3100`. Override it when needed:

```bash
PENGUINCHAT_API_URL=http://127.0.0.1:3000 npm run acceptance:two-user
```

The harness verifies registration and login, friend request send/accept,
offline and online presence, messages in both directions, typing start/stop,
delivered/read transitions, retry idempotency, forced disconnect/reconnect, and
identical duplicate-free history on both sides. It prints one JSON result with
`"ok": true` on success and exits nonzero on the first failed assertion.

For the native client regression gate, run:

```bash
cd macos/PenguinChatMac
swift test
swift build -c release
```
