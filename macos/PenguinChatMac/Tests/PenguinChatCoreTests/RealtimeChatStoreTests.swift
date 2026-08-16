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
    #expect(snapshot.messages[0].outboundState == .failed(reason: "acknowledgementTimedOut"))
    #expect(await transport.deliveredIDs == ["m-1"])
    #expect(await transport.readRequests.count == 1)
    #expect(await transport.typingRequests.count == 1)
    await store.stop()
}
