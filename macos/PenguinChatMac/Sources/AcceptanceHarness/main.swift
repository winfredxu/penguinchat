import Foundation
import PenguinChatCore
import PenguinChatSocketIO

// Two-user acceptance run for the native macOS client (WINL-12).
//
// Drives two full client stacks against a live PenguinChat server over REST and
// Socket.IO and asserts the parent acceptance criteria: friend requests,
// presence, bidirectional messaging, typing, delivered/read receipts, forced
// reconnect, history convergence, and duplicate suppression.
//
// Point it at a server with PENGUINCHAT_API_URL (default http://127.0.0.1:3000).

let environment = AppEnvironment.resolve()
let report = Report()
// Registration-only credential, never persisted; the harness creates throwaway
// users per run so it can be re-run against the same database.
let password = "qa-\(UUID().uuidString.prefix(12))"

print("PenguinChat macOS two-user acceptance")
print("server: \(environment.apiBaseURL.absoluteString)")
print("")

// MARK: - Prerequisites

struct Health: Decodable, Sendable { let status: String }
let probe = APIClient(baseURL: environment.apiBaseURL)
do {
    let health: Health = try await probe.request("/health")
    report.check("server reachable and healthy", health.status == "ok", detail: health.status)
} catch {
    report.check("server reachable and healthy", false, detail: String(describing: error))
    report.note("start the server first: docker compose up -d api")
    report.summarize()
    exit(1)
}

// MARK: - Registration and login prerequisites

let alice: Participant
let bob: Participant
do {
    alice = try await Participant.register(label: "a", environment: environment, password: password)
    bob = try await Participant.register(label: "b", environment: environment, password: password)
    report.check("two users register and receive sessions", true)
    report.note("users: \(alice.username), \(bob.username)")
} catch {
    report.check("two users register and receive sessions", false, detail: String(describing: error))
    report.summarize()
    exit(1)
}

// A fresh login must work for an already-registered account, and the restored
// session must resolve to the same identity.
do {
    let reloginClient = APIClient(baseURL: environment.apiBaseURL)
    let relogin = SessionManager(
        authService: AuthService(client: reloginClient),
        credentialStore: InMemoryCredentialStore()
    )
    let session = try await relogin.login(username: alice.username, password: password)
    report.check("login returns the same identity as registration", session.user.id == alice.user.id)
    let restored = try await relogin.restore()
    report.check("saved session restores", restored?.user.id == alice.user.id)
} catch {
    report.check("login and restore succeed", false, detail: String(describing: error))
}

// MARK: - Friend request send and accept

do {
    let sent = try await alice.sendFriendRequest(to: bob.username)
    report.check("friend request is created", sent.status == "pending")

    let incoming = try await bob.incomingRequests()
    let pending = incoming.first { $0.id == sent.id }
    report.check("recipient sees the incoming request", pending != nil)

    if let pending {
        let friendID = try await bob.acceptFriendRequest(id: pending.id)
        report.check("accept returns the new friend id", friendID == alice.user.id)
    }

    try await alice.refreshContacts()
    try await bob.refreshContacts()

    let aliceContacts = await alice.store.snapshot().contacts
    let bobContacts = await bob.store.snapshot().contacts
    report.check(
        "both rosters contain exactly one contact — the peer",
        aliceContacts.count == 1 && aliceContacts.first?.id == bob.user.id &&
        bobContacts.count == 1 && bobContacts.first?.id == alice.user.id,
        detail: "alice=\(aliceContacts.count) bob=\(bobContacts.count)"
    )
    let bobRequests = await bob.store.snapshot().incomingRequests
    report.check("accepted request leaves the pending list", bobRequests.isEmpty)
} catch {
    report.check("friend request send and accept", false, detail: String(describing: error))
    report.summarize()
    exit(1)
}

// MARK: - Realtime connection and initial presence

await alice.chat.start()
await bob.chat.start()

let aliceConnected = await waitFor { if case .connected = await alice.store.snapshot().connection { return true }; return false }
let bobConnected = await waitFor { if case .connected = await bob.store.snapshot().connection { return true }; return false }
report.check("both clients connect over Socket.IO", aliceConnected && bobConnected)

// Alice learns Bob is online from the live `presence:update` he emits on connect.
// Bob connected first from his own point of view, so he reconciles Alice's
// current presence from the REST snapshot — the same split the app relies on.
let alicePresence = await waitFor {
    await alice.store.snapshot().presenceByUserID[bob.user.id] == .online
}
report.check("live presence:update marks the peer online", alicePresence)

try? await bob.refreshContacts()
let bobPresence = await waitFor {
    await bob.store.snapshot().presenceByUserID[alice.user.id] == .online
}
report.check("REST presence snapshot converges with live state", bobPresence)

// MARK: - Bidirectional messaging, delivery, unread, and read receipts

await alice.chat.select(peerID: bob.user.id)

let firstBody = "hello from alice \(UUID().uuidString.prefix(6))"
let didSend = await alice.chat.send(firstBody)
report.check("sender accepts the outbound message", didSend)

report.check(
    "outbound message is acknowledged and leaves pending",
    await waitFor {
        guard let message = await alice.store.snapshot().messages.first(where: { $0.body == firstBody })
        else { return false }
        return message.serverID != nil && message.outboundState == .sent
    }
)

report.check(
    "recipient receives the message in real time",
    await waitFor { await bob.store.snapshot().messages.contains { $0.body == firstBody } }
)

// The recipient's store emits `message:delivered` on receipt, so the sender's
// copy gains a delivered timestamp without any UI involvement.
report.check(
    "sender observes the delivery receipt",
    await waitFor {
        await alice.store.snapshot().messages.first { $0.body == firstBody }?.deliveredAt != nil
    }
)

// Bob has no conversation selected, so nothing may mark it read yet.
report.check(
    "unselected conversation reports one unread message",
    await waitFor {
        bob.chat.conversations.first { $0.id == alice.user.id }?.unreadCount == 1
    }
)
report.check(
    "delivered-but-unread message carries no read timestamp",
    await alice.store.snapshot().messages.first { $0.body == firstBody }?.readAt == nil
)

// Selecting the conversation loads history and emits the read receipt.
await bob.chat.select(peerID: alice.user.id)
report.check(
    "selecting the conversation clears its unread count",
    await waitFor {
        bob.chat.conversations.first { $0.id == alice.user.id }?.unreadCount == 0
    }
)
report.check(
    "sender observes the read receipt",
    await waitFor {
        await alice.store.snapshot().messages.first { $0.body == firstBody }?.readAt != nil
    }
)

// Reply direction.
let replyBody = "hello back from bob \(UUID().uuidString.prefix(6))"
report.check("recipient can reply", await bob.chat.send(replyBody))
report.check(
    "reply arrives, is delivered, and is read",
    await waitFor {
        guard let message = await bob.store.snapshot().messages.first(where: { $0.body == replyBody })
        else { return false }
        return message.deliveredAt != nil && message.readAt != nil
    }
)

// MARK: - Typing indicator

alice.chat.composerDidChange("drafting a reply")
report.check(
    "peer sees the typing indicator",
    await waitFor(timeout: .seconds(10)) { bob.chat.isPeerTyping }
)
// The composer's idle timer emits typing:stop without further input.
report.check(
    "typing indicator clears when composing stops",
    await waitFor(timeout: .seconds(10)) { bob.chat.isPeerTyping == false }
)

// MARK: - Forced disconnect, reconnect, and history convergence

let messagesBeforeDrop = await alice.store.snapshot().messages.count

await alice.store.stop()
report.check(
    "forced disconnect is observed",
    await waitFor {
        if case .disconnected = await alice.store.snapshot().connection { return true }
        return false
    }
)
report.check(
    "peer sees the disconnected client go offline",
    await waitFor(timeout: .seconds(20)) {
        await bob.store.snapshot().presenceByUserID[alice.user.id] == .offline
    }
)

// Messages sent while the peer is offline must appear after reconnect, sourced
// from the history refetch rather than the live stream.
let offlineBody = "sent while alice was offline \(UUID().uuidString.prefix(6))"
report.check("peer can send while the other client is offline", await bob.chat.send(offlineBody))
report.check(
    "offline-sent message is persisted server-side",
    await waitFor {
        guard let message = await bob.store.snapshot().messages.first(where: { $0.body == offlineBody })
        else { return false }
        return message.serverID != nil
    }
)

try? await alice.store.start()
report.check(
    "client reconnects",
    await waitFor(timeout: .seconds(30)) {
        if case .connected = await alice.store.snapshot().connection { return true }
        return false
    }
)
report.check(
    "reconnect refetches the message missed while offline",
    await waitFor(timeout: .seconds(30)) {
        await alice.store.snapshot().messages.contains { $0.body == offlineBody }
    }
)
report.check(
    "presence converges again after reconnect",
    await waitFor(timeout: .seconds(20)) {
        await bob.store.snapshot().presenceByUserID[alice.user.id] == .online
    }
)

// MARK: - Duplicate suppression and convergence

let aliceMessages = await alice.store.snapshot().messages
let bobMessages = await bob.store.snapshot().messages

let aliceServerIDs = aliceMessages.compactMap(\.serverID)
let bobServerIDs = bobMessages.compactMap(\.serverID)
report.check(
    "no duplicate server ids after ack, live echo, and history refetch",
    Set(aliceServerIDs).count == aliceServerIDs.count &&
    Set(bobServerIDs).count == bobServerIDs.count,
    detail: "alice \(aliceServerIDs.count)/\(Set(aliceServerIDs).count), bob \(bobServerIDs.count)/\(Set(bobServerIDs).count)"
)
report.check(
    "every message resolved to a server id",
    aliceServerIDs.count == aliceMessages.count && bobServerIDs.count == bobMessages.count
)
report.check(
    "both clients converge on the same conversation",
    Set(aliceServerIDs) == Set(bobServerIDs),
    detail: "alice=\(aliceServerIDs.count) bob=\(bobServerIDs.count)"
)
report.check(
    "reconnect added the missed message without losing earlier ones",
    aliceMessages.count == messagesBeforeDrop + 1,
    detail: "before=\(messagesBeforeDrop) after=\(aliceMessages.count)"
)
report.check(
    "messages are ordered deterministically by timestamp",
    aliceMessages.map(\.createdAt) == aliceMessages.map(\.createdAt).sorted()
)

// MARK: - History pagination against the live endpoint

// The reconciliation store is unit-tested with fakes; what only a live server can
// confirm is the `limit` / `before` contract and that re-merging real payloads
// still collapses onto the same rows.
do {
    let history = MessageHistoryService(client: APIClient(baseURL: environment.apiBaseURL))
    let token = await alice.accessToken
    let firstPage = try await history.history(with: bob.user.id, before: nil, limit: 1, accessToken: token)
    report.check("history honors the page limit", firstPage.count == 1, detail: "got \(firstPage.count)")

    if let newest = firstPage.first {
        let olderPage = try await history.history(
            with: bob.user.id,
            before: newest.createdAt,
            limit: 10,
            accessToken: token
        )
        report.check(
            "the before cursor returns strictly older messages",
            !olderPage.isEmpty && olderPage.allSatisfy { $0.createdAt < newest.createdAt },
            detail: "got \(olderPage.count)"
        )

        // Re-merging pages the store already holds must not duplicate rows.
        let countBefore = await alice.store.snapshot().messages.count
        await alice.store.mergeHistory(firstPage + olderPage, peerID: bob.user.id)
        let countAfter = await alice.store.snapshot().messages.count
        report.check(
            "re-merging live history pages creates no duplicates",
            countBefore == countAfter,
            detail: "before=\(countBefore) after=\(countAfter)"
        )
    }
} catch {
    report.check("history pagination against the live endpoint", false, detail: String(describing: error))
}

// MARK: - Restart restore through the real Keychain (WINL-7)

// The other restore check uses an in-memory store, which proves the
// SessionManager logic but not that a relaunched app finds its session. This
// one writes to the actual Keychain — under a QA-only service name so the
// shipping app's item is untouched — and reads it back through a brand new
// SessionManager, which is what a cold launch does.
do {
    let service = "com.penguinchat.macos.acceptance.\(UUID().uuidString)"
    let write = KeychainTokenStore(service: service, account: "current-session")
    let first = SessionManager(
        authService: AuthService(client: APIClient(baseURL: environment.apiBaseURL)),
        credentialStore: write
    )
    _ = try await first.login(username: bob.username, password: password)

    // A separate store instance over the same service = a new process.
    let relaunched = SessionManager(
        authService: AuthService(client: APIClient(baseURL: environment.apiBaseURL)),
        credentialStore: KeychainTokenStore(service: service, account: "current-session")
    )
    let restored = try await relaunched.restore()
    report.check(
        "session persisted in the Keychain restores after a simulated restart",
        restored?.user.id == bob.user.id,
        detail: restored.map { "restored \($0.user.username)" } ?? "nothing restored"
    )

    try await relaunched.logout()
    let afterLogout = try await KeychainTokenStore(service: service, account: "current-session").loadTokens()
    report.check("sign-out removes the Keychain item", afterLogout == nil)
    // Best effort: logout already deleted it, but never leave a QA item behind.
    try? await write.deleteTokens()
} catch {
    report.check("Keychain restart restore", false, detail: Redaction.describe(error))
}

// MARK: - Manual reconnect and unread surfaces (WINL-7)

// ⇧⌘R calls store.reconnect() — including after a full stop(), where the event
// task has to be re-subscribed and not just re-dialed.
await bob.store.stop()
report.check(
    "stop() reports the realtime connection offline",
    await waitFor {
        if case .connected = await bob.store.snapshot().connection { return false }
        return true
    }
)
await bob.store.reconnect()
report.check(
    "manual reconnect restores the connection after a full stop",
    await waitFor(timeout: .seconds(20)) {
        if case .connected = await bob.store.snapshot().connection { return true }
        return false
    }
)

// The Dock badge and notification decisions run off the same projection the UI
// renders, so they are asserted against the live conversation rather than fakes.
do {
    let planner = NotificationPlanner()
    let conversations = bob.chat.conversations
    let seeded = planner.plan(
        conversations: conversations,
        currentUserID: bob.user.id,
        selectedPeerID: nil,
        isAppActive: false
    )
    report.check("the first projection after launch raises no notifications", seeded.isEmpty)

    // Earlier sections left alice's thread selected on bob's side, which
    // auto-marks arrivals read. Deselect so the probe lands as genuine unread.
    await bob.chat.select(peerID: nil)
    let unreadBefore = bob.chat.conversations.reduce(0) { $0 + $1.unreadCount }
    _ = await alice.chat.select(peerID: bob.user.id)
    let banner = "notification probe \(UUID().uuidString.prefix(6))"
    _ = await alice.chat.send(banner)

    let arrived = await waitFor {
        bob.chat.conversations.contains { $0.lastMessage?.body == banner }
    }
    report.check("the probe message reaches the peer", arrived)

    let pending = planner.plan(
        conversations: bob.chat.conversations,
        currentUserID: bob.user.id,
        selectedPeerID: nil,
        isAppActive: false
    )
    report.check(
        "an unread message from an unselected thread plans one notification",
        pending.count == 1 && pending.first?.body == banner,
        detail: "planned \(pending.count)"
    )
    report.check(
        "the notification is attributed to the sending peer",
        pending.first?.peerID == alice.user.id
    )

    let repeated = planner.plan(
        conversations: bob.chat.conversations,
        currentUserID: bob.user.id,
        selectedPeerID: nil,
        isAppActive: false
    )
    report.check("a re-published snapshot does not notify twice", repeated.isEmpty)

    let unreadAfter = bob.chat.conversations.reduce(0) { $0 + $1.unreadCount }
    report.check(
        "the unread total the Dock badge uses increases by one",
        unreadAfter == unreadBefore + 1,
        detail: "before=\(unreadBefore) after=\(unreadAfter)"
    )
    report.check(
        "the badge label matches the unread total",
        NotificationPlanner.badgeLabel(unreadCount: unreadAfter) == String(unreadAfter),
        detail: NotificationPlanner.badgeLabel(unreadCount: unreadAfter) ?? "nil"
    )

    // Opening the thread clears both the unread count and the badge.
    _ = await bob.chat.select(peerID: alice.user.id)
    let cleared = await waitFor {
        bob.chat.conversations.allSatisfy { $0.unreadCount == 0 }
    }
    report.check("selecting the thread clears the unread badge", cleared)
    report.check(
        "a zero unread total hides the Dock badge",
        NotificationPlanner.badgeLabel(unreadCount: 0) == nil
    )
}

// MARK: - Log and error redaction (WINL-7)

// Failure reasons reach the UI and the log; a leaked token there would outlive
// the session it belongs to.
let secretToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJxYSJ9.s3cr3t-signature-value"
let redactedError = Redaction.redact("connect failed: {\"token\": \"\(secretToken)\"}")
report.check(
    "redaction strips a token out of a diagnostic string",
    !redactedError.contains(secretToken) && !redactedError.contains("s3cr3t"),
    detail: redactedError
)
report.check(
    "redaction strips an Authorization header",
    !Redaction.redact("Authorization: Bearer \(secretToken)").contains(secretToken)
)
report.check(
    "transport errors describe themselves without payloads",
    Redaction.describe(RealtimeTransportError.notConnected) == "not_connected"
)

// MARK: - Teardown

await alice.chat.stop()
await bob.chat.stop()
await alice.store.stop()
await bob.store.stop()

report.note("conversation length: \(await alice.store.snapshot().messages.count) messages")
report.summarize()
exit(report.failures.isEmpty ? 0 : 1)
