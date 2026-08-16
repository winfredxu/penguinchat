import Foundation
import Testing
@testable import PenguinChatCore

private actor FakeRealtimeTransport: RealtimeTransport {
    let stream: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    var connectedTokens: [String] = []
    var sentRequests: [SendMessageRequest] = []
    var acknowledgements: [SendAcknowledgement] = []
    var deliveredIDs: [String] = []
    var readRequests: [(String, String)] = []
    var typingRequests: [(Bool, String)] = []

    init() {
        (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
    }

    func events() async -> AsyncStream<RealtimeEvent> { stream }
    func connect(accessToken: String) async { connectedTokens.append(accessToken) }
    func disconnect() async {}

    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        sentRequests.append(request)
        guard !acknowledgements.isEmpty else { throw RealtimeTransportError.acknowledgementTimedOut }
        return acknowledgements.removeFirst()
    }

    func confirmDelivered(messageID: String) async throws { deliveredIDs.append(messageID) }
    func markRead(peerID: String, upToMessageID: String) async throws { readRequests.append((peerID, upToMessageID)) }
    func setTyping(_ isTyping: Bool, toUserID: String) async throws { typingRequests.append((isTyping, toUserID)) }
    func emit(_ event: RealtimeEvent) { continuation.yield(event) }
    func enqueue(_ acknowledgement: SendAcknowledgement) { acknowledgements.append(acknowledgement) }
}

private actor FakeRealtimeCredentials: RealtimeCredentialProviding {
    var accessToken: String?
    var refreshedToken: String?
    var refreshCount = 0

    init(accessToken: String?, refreshedToken: String? = nil) {
        self.accessToken = accessToken
        self.refreshedToken = refreshedToken
    }

    func realtimeAccessToken() async -> String? { accessToken }

    func refreshRealtimeAccessToken() async throws -> String? {
        refreshCount += 1
        accessToken = refreshedToken
        return refreshedToken
    }
}

private actor DelayedAckTransport: RealtimeTransport {
    let stream: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    private var acknowledgementWaiter: CheckedContinuation<SendAcknowledgement, Error>?
    var sentRequests: [SendMessageRequest] = []

    init() { (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self) }
    func events() async -> AsyncStream<RealtimeEvent> { stream }
    func connect(accessToken: String) async {}
    func disconnect() async {}
    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        sentRequests.append(request)
        return try await withCheckedThrowingContinuation { acknowledgementWaiter = $0 }
    }
    func confirmDelivered(messageID: String) async throws {}
    func markRead(peerID: String, upToMessageID: String) async throws {}
    func setTyping(_ isTyping: Bool, toUserID: String) async throws {}
    func release(_ acknowledgement: SendAcknowledgement) {
        acknowledgementWaiter?.resume(returning: acknowledgement)
        acknowledgementWaiter = nil
    }
}

private actor FakeMessageHistoryService: MessageHistoryServing {
    var responses: [String: [ChatMessage]]
    var calls: [String] = []
    private var shouldSuspend = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(responses: [String: [ChatMessage]] = [:]) { self.responses = responses }

    func suspendNextRequest() { shouldSuspend = true }
    func releaseRequest() { waiter?.resume(); waiter = nil }

    func history(with peerID: String, before: String?, limit: Int, accessToken: String) async throws -> [ChatMessage] {
        calls.append(peerID)
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { waiter = $0 }
        }
        return responses[peerID] ?? []
    }
}

private func message(
    id: String,
    sender: String = "alice",
    recipient: String = "bob",
    body: String,
    createdAt: String
) -> ChatMessage {
    ChatMessage(
        id: id,
        conversation: "conversation-1",
        senderID: sender,
        recipientID: recipient,
        body: body,
        createdAt: createdAt
    )
}

private func makeStore(
    transport: FakeRealtimeTransport,
    credentials: FakeRealtimeCredentials,
    history: FakeMessageHistoryService
) -> RealtimeChatStore {
    RealtimeChatStore(
        transport: transport,
        credentials: credentials,
        historyService: history,
        currentUserID: "alice"
    )
}

private func eventually(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
}

@Test func duplicateAndOutOfOrderSnapshotsConvergeDeterministically() async {
    let transport = FakeRealtimeTransport()
    let credentials = FakeRealtimeCredentials(accessToken: "token")
    let history = FakeMessageHistoryService()
    let store = makeStore(transport: transport, credentials: credentials, history: history)
    let early = message(id: "m-1", body: "first", createdAt: "2026-08-15T10:00:00.000Z")
    let late = message(id: "m-2", body: "second", createdAt: "2026-08-15T10:00:01.000Z")

    await store.mergeHistory([late, early, late], peerID: "bob")

    let snapshot = await store.snapshot()
    #expect(snapshot.messages.map(\.serverID) == ["m-1", "m-2"])
}

@Test func sendAcknowledgementAndDuplicateSnapshotKeepOneSentMessage() async {
    let transport = FakeRealtimeTransport()
    await transport.enqueue(SendAcknowledgement(
        id: "server-1",
        createdAt: "2026-08-15T10:00:00.000Z",
        clientMessageID: "client-1",
        error: nil
    ))
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )

    _ = await store.send(body: "hello", to: "bob", clientMessageID: "client-1")
    await store.mergeHistory([
        message(id: "server-1", body: "hello", createdAt: "2026-08-15T10:00:00.000Z")
    ], peerID: "bob")

    let snapshot = await store.snapshot()
    #expect(snapshot.messages.count == 1)
    #expect(snapshot.messages[0].clientMessageID == "client-1")
    #expect(snapshot.messages[0].outboundState == .sent)
}

@Test func historyArrivingBeforeAcknowledgementReconcilesTheOptimisticMessage() async throws {
    let transport = DelayedAckTransport()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        historyService: FakeMessageHistoryService(),
        currentUserID: "alice"
    )
    let sendTask = Task {
        await store.send(body: "racing", to: "bob", clientMessageID: "client-race")
    }
    try await eventually { await transport.sentRequests.count == 1 }

    await store.mergeHistory([
        message(id: "server-race", body: "racing", createdAt: "2026-08-15T10:00:00.000Z")
    ], peerID: "bob")
    await transport.release(SendAcknowledgement(
        id: "server-race",
        createdAt: "2026-08-15T10:00:00.000Z",
        clientMessageID: "client-race",
        error: nil
    ))
    _ = await sendTask.value

    let snapshot = await store.snapshot()
    #expect(snapshot.messages.count == 1)
    #expect(snapshot.messages[0].serverID == "server-race")
    #expect(snapshot.messages[0].clientMessageID == "client-race")
}

@Test func duplicateLiveMessageAndDeliveryEventsAreIdempotent() async throws {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )
    try await store.start()
    let incoming = message(
        id: "server-duplicate",
        sender: "bob",
        recipient: "alice",
        body: "once",
        createdAt: "2026-08-15T10:00:00.000Z"
    )

    await transport.emit(.message(NewMessageEvent(message: incoming)))
    await transport.emit(.message(NewMessageEvent(message: incoming)))
    await transport.emit(.delivery(DeliveryEvent(
        messageID: "server-duplicate",
        deliveredAt: "2026-08-15T10:00:01.000Z"
    )))
    await transport.emit(.delivery(DeliveryEvent(
        messageID: "server-duplicate",
        deliveredAt: "2026-08-15T10:00:01.000Z"
    )))
    try await eventually { await store.snapshot().messages.first?.deliveredAt != nil }

    let snapshot = await store.snapshot()
    #expect(snapshot.messages.count == 1)
    #expect(snapshot.messages[0].deliveredAt == "2026-08-15T10:00:01.000Z")
    await store.stop()
}

@Test func reconnectRefetchesHistoryBeforeApplyingBufferedLiveEvents() async throws {
    let transport = FakeRealtimeTransport()
    let credentials = FakeRealtimeCredentials(accessToken: "token")
    let historyMessage = message(id: "m-2", body: "snapshot", createdAt: "2026-08-15T10:00:02.000Z")
    let liveMessage = message(id: "m-3", sender: "bob", recipient: "alice", body: "live", createdAt: "2026-08-15T10:00:03.000Z")
    let history = FakeMessageHistoryService(responses: ["bob": [historyMessage]])
    await history.suspendNextRequest()
    let store = makeStore(transport: transport, credentials: credentials, history: history)
    await store.mergeHistory([], peerID: "bob")
    try await store.start()

    await transport.emit(.connection(.connected(isReconnect: true)))
    try await eventually { await history.calls == ["bob"] }
    await transport.emit(.message(NewMessageEvent(message: liveMessage)))
    await history.releaseRequest()
    try await eventually { await store.snapshot().messages.count == 2 }

    #expect(await store.snapshot().messages.map(\.serverID) == ["m-2", "m-3"])
    await store.stop()
}

@Test func authenticationFailureRefreshesThroughSessionBoundaryAndReconnects() async throws {
    let transport = FakeRealtimeTransport()
    let credentials = FakeRealtimeCredentials(accessToken: "expired", refreshedToken: "rotated")
    let store = makeStore(
        transport: transport,
        credentials: credentials,
        history: FakeMessageHistoryService()
    )
    try await store.start()
    await transport.emit(.connection(.authenticationFailed))

    try await eventually { await transport.connectedTokens == ["expired", "rotated"] }

    #expect(await credentials.refreshCount == 1)
    await store.stop()
}

@Test func fakeTransportDrivesPresenceTypingReceiptsAndFailures() async throws {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )
    try await store.start()
    await transport.emit(.presence(PresenceUpdate(userID: "bob", status: .online)))
    await transport.emit(.typing(TypingEvent(fromUserID: "bob", isTyping: true)))
    _ = await store.send(body: "will fail", to: "bob", clientMessageID: "failed-1")
    try await store.confirmDelivered(messageID: "m-1")
    try await store.markRead(peerID: "bob", upToMessageID: "m-1")
    try await store.setTyping(true, to: "bob")
    try await eventually { await store.snapshot().typingUserIDs.contains("bob") }

    let snapshot = await store.snapshot()
    #expect(snapshot.presenceByUserID["bob"] == .online)
    // The failure reason is the redacted form, not `String(describing:)`.
    #expect(snapshot.messages[0].outboundState == .failed(reason: "ack_timeout"))
    #expect(await transport.deliveredIDs == ["m-1"])
    #expect(await transport.readRequests.count == 1)
    #expect(await transport.typingRequests.count == 1)
    await store.stop()
}

@Test func failedMessageRetriesWithTheSameStableClientIdentifier() async {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )

    _ = await store.send(body: "retry me", to: "bob", clientMessageID: "stable-client-id")
    await transport.enqueue(SendAcknowledgement(
        id: "server-after-retry",
        createdAt: "2026-08-15T10:00:00.000Z",
        clientMessageID: "stable-client-id",
        error: nil
    ))
    await store.retry(clientMessageID: "stable-client-id")

    #expect(await transport.sentRequests.map(\.clientMessageID) == ["stable-client-id", "stable-client-id"])
    let snapshot = await store.snapshot()
    #expect(snapshot.messages.count == 1)
    #expect(snapshot.messages[0].serverID == "server-after-retry")
    #expect(snapshot.messages[0].outboundState == .sent)
}

@Test func incomingMessageAutomaticallyConfirmsDeliveryAndVisibleReadClearsUnreadState() async throws {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )
    try await store.start()
    let incoming = message(
        id: "incoming-1",
        sender: "bob",
        recipient: "alice",
        body: "hello",
        createdAt: "2026-08-15T10:00:00.000Z"
    )

    await transport.emit(.message(NewMessageEvent(message: incoming)))
    try await eventually { await transport.deliveredIDs == ["incoming-1"] }
    try await store.markVisibleRead(peerID: "bob", upToMessageID: "incoming-1")

    #expect(await transport.readRequests.count == 1)
    #expect(await store.snapshot().messages[0].readAt != nil)
    await store.stop()
}

@Test func typingIndicatorExpiresWithoutAStopEvent() async throws {
    let transport = FakeRealtimeTransport()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        historyService: FakeMessageHistoryService(),
        currentUserID: "alice",
        typingTimeout: .milliseconds(25)
    )
    try await store.start()

    await transport.emit(.typing(TypingEvent(fromUserID: "bob", isTyping: true)))
    try await eventually { await store.snapshot().typingUserIDs.contains("bob") }
    try await eventually { !(await store.snapshot().typingUserIDs.contains("bob")) }

    await store.stop()
}

/// The server derives conversation IDs as a UUID v5 hash, but an optimistically
/// sent message carries a local placeholder and the send acknowledgement does
/// not return the server's value. A read receipt must still land on it.
@Test func readReceiptMarksOptimisticallySentMessageDespiteConversationIDMismatch() async throws {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )
    try await store.start()
    await transport.enqueue(SendAcknowledgement(
        id: "server-1",
        createdAt: "2024-01-01T00:00:00Z",
        clientMessageID: "local-1",
        error: nil
    ))
    _ = await store.send(body: "hello", to: "bob", clientMessageID: "local-1")

    // The local placeholder never equals the server's hashed conversation id.
    let stored = await store.snapshot().messages[0]
    #expect(stored.conversationID != "server-derived-uuid-v5")
    #expect(stored.readAt == nil)

    await transport.emit(.read(ReadEvent(
        conversationID: "server-derived-uuid-v5",
        upToMessageID: "server-1"
    )))
    try await eventually { await store.snapshot().messages[0].readAt != nil }
    await store.stop()
}

/// A read receipt whose boundary message we did not send must not mark our own
/// outbound messages read.
@Test func readReceiptForIncomingBoundaryDoesNotMarkOutboundMessages() async throws {
    let transport = FakeRealtimeTransport()
    let store = makeStore(
        transport: transport,
        credentials: FakeRealtimeCredentials(accessToken: "token"),
        history: FakeMessageHistoryService()
    )
    try await store.start()
    await transport.enqueue(SendAcknowledgement(
        id: "mine-1",
        createdAt: "2024-01-01T00:00:00Z",
        clientMessageID: "local-1",
        error: nil
    ))
    _ = await store.send(body: "mine", to: "bob", clientMessageID: "local-1")
    await store.mergeHistory([
        message(id: "theirs-1", sender: "bob", recipient: "alice", body: "theirs", createdAt: "2024-01-01T00:00:05Z"),
    ], peerID: "bob")

    await transport.emit(.read(ReadEvent(conversationID: "any", upToMessageID: "theirs-1")))
    try await eventually { await store.snapshot().messages.count == 2 }
    let mine = await store.snapshot().messages.first { $0.serverID == "mine-1" }
    #expect(mine?.readAt == nil)
    await store.stop()
}

// MARK: - Manual reconnect (⇧⌘R / the offline banner)

/// Hands out a fresh stream per `events()` call, the way the Socket.IO
/// transport does. `FakeRealtimeTransport` shares one stream, which cannot be
/// iterated twice — so it can't express a resubscribe.
private actor ResubscribingTransport: RealtimeTransport {
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    var connectedTokens: [String] = []
    var subscriptions = 0

    func events() async -> AsyncStream<RealtimeEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self)
        self.continuation?.finish()
        self.continuation = continuation
        subscriptions += 1
        return stream
    }

    func connect(accessToken: String) async { connectedTokens.append(accessToken) }
    func disconnect() async {}
    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        throw RealtimeTransportError.notConnected
    }
    func confirmDelivered(messageID: String) async throws {}
    func markRead(peerID: String, upToMessageID: String) async throws {}
    func setTyping(_ isTyping: Bool, toUserID: String) async throws {}
    func emit(_ event: RealtimeEvent) { continuation?.yield(event) }
}

/// After a full `stop()` the event task is gone, so reconnect has to
/// re-subscribe as well as re-dial — otherwise the socket comes back but no
/// events ever reach the store again.
@Test func reconnectAfterStopRedialsAndResumesEventDelivery() async throws {
    let transport = ResubscribingTransport()
    let credentials = FakeRealtimeCredentials(accessToken: "token")
    let store = RealtimeChatStore(
        transport: transport,
        credentials: credentials,
        historyService: FakeMessageHistoryService(),
        currentUserID: "alice"
    )
    try await store.start()
    await store.stop()

    await store.reconnect()
    #expect(await transport.connectedTokens == ["token", "token"])
    #expect(await transport.subscriptions == 2)

    await transport.emit(.connection(.connected(isReconnect: false)))
    try await eventually { await store.snapshot().connection == .connected(isReconnect: false) }

    await transport.emit(.presence(PresenceUpdate(userID: "bob", status: .online)))
    try await eventually { await store.snapshot().presenceByUserID["bob"] == .online }
    await store.stop()
}

@Test func reconnectRefreshesAnExpiredAccessToken() async throws {
    let transport = FakeRealtimeTransport()
    let credentials = FakeRealtimeCredentials(accessToken: nil, refreshedToken: "fresh")
    let store = makeStore(transport: transport, credentials: credentials, history: FakeMessageHistoryService())

    await store.reconnect()
    #expect(await credentials.refreshCount == 1)
    #expect(await transport.connectedTokens == ["fresh"])
    #expect(await store.snapshot().connection == .connecting)
    await store.stop()
}

@Test func reconnectWithoutAnyCredentialReportsAuthenticationFailure() async throws {
    let transport = FakeRealtimeTransport()
    let credentials = FakeRealtimeCredentials(accessToken: nil)
    let store = makeStore(transport: transport, credentials: credentials, history: FakeMessageHistoryService())

    await store.reconnect()
    #expect(await store.snapshot().connection == .authenticationFailed)
    #expect(await transport.connectedTokens.isEmpty)
}
