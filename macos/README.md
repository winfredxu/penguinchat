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
and service protocols) from the `PenguinChatMac` SwiftUI executable. This keeps
network behavior testable without launching the app and leaves room for
Keychain/session and realtime implementations.

## Build, test, and run

Start the API on port 3000, then run:

```bash
cd macos/PenguinChatMac
swift test
swift build
swift run PenguinChatMac
```

You can also open `macos/PenguinChatMac/Package.swift` in Xcode, select the
`PenguinChatMac` scheme, and Run. The app presents a native login placeholder;
“预览会话” switches to the native three-column session shell.

Debug uses `http://127.0.0.1:3000` for both REST and Socket.IO. Override it in
the Xcode scheme or shell:

```bash
PENGUINCHAT_API_URL=http://127.0.0.1:3100 swift run PenguinChatMac
```

Only `http` and `https` origins with a host are accepted; invalid overrides
fall back to the local endpoint. API and event details are recorded in
`docs/macos-api-contract.md`.
