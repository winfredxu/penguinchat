import Foundation
import Testing
@testable import PenguinChatCore

private actor ChatFakeTransport: RealtimeTransport {
    let stream: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation
    var reads: [(String, String)] = []
    var typing: [(Bool, String)] = []

    init() { (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self) }
    func events() async -> AsyncStream<RealtimeEvent> { stream }
    func connect(accessToken: String) async {}
    func disconnect() async {}
    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        SendAcknowledgement(
            id: "server-\(request.clientMessageID)",
            createdAt: "2026-08-16T10:00:05.000Z",
            clientMessageID: request.clientMessageID,
            error: nil
        )
    }
    func confirmDelivered(messageID: String) async throws {}
    func markRead(peerID: String, upToMessageID: String) async throws { reads.append((peerID, upToMessageID)) }
    func setTyping(_ isTyping: Bool, toUserID: String) async throws { typing.append((isTyping, toUserID)) }
}

private actor ChatFakeCredentials: RealtimeCredentialProviding {
    func realtimeAccessToken() async -> String? { "token" }
    func refreshRealtimeAccessToken() async throws -> String? { "refreshed" }
}

private actor PagedHistory: MessageHistoryServing {
    var pages: [[ChatMessage]]
    var calls: [(String, String?)] = []

    init(_ pages: [[ChatMessage]]) { self.pages = pages }

    func history(with peerID: String, before: String?, limit: Int, accessToken: String) async throws -> [ChatMessage] {
        calls.append((peerID, before))
        return pages.isEmpty ? [] : pages.removeFirst()
    }

    func recordedCalls() -> [(String, String?)] { calls }
}

private func chatMessage(
    _ id: String,
    from sender: String,
    to recipient: String,
    at createdAt: String,
    body: String = "hello"
) -> ChatMessage {
    ChatMessage(
        id: id,
        conversation: [sender, recipient].sorted().joined(separator: ":"),
        senderID: sender,
        recipientID: recipient,
        body: body,
        createdAt: createdAt
    )
}

private func contact(_ id: String, _ name: String) -> Contact {
    Contact(
        id: id,
        username: id,
        displayName: name,
        createdAt: "2026-08-16T00:00:00.000Z",
        presence: .online
    )
}

@MainActor
private func eventuallyMain(_ predicate: @escaping @MainActor () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
}

@Test @MainActor
func conversationProjectionOrdersByLatestMessageAndTracksUnread() async throws {
    let transport = ChatFakeTransport()
    let history = PagedHistory([[]])
    let store = RealtimeChatStore(
        transport: transport,
        credentials: ChatFakeCredentials(),
        historyService: history,
        currentUserID: "alice"
    )
    await store.replaceSocialSnapshot(contacts: [contact("bob", "Bob"), contact("carol", "Carol")], incomingRequests: [])
    await store.mergeHistory([
        chatMessage("bob-1", from: "bob", to: "alice", at: "2026-08-16T10:00:01.000Z"),
        chatMessage("carol-1", from: "carol", to: "alice", at: "2026-08-16T10:00:02.000Z"),
    ], peerID: "bob")
    let model = ChatViewModel(
        historyService: history,
        credentials: ChatFakeCredentials(),
        store: store,
        currentUserID: "alice"
    )
    await model.start()

    try await eventuallyMain { model.conversations.map(\.id) == ["carol", "bob"] }
    #expect(model.conversations.map(\.unreadCount) == [1, 1])

    await model.select(peerID: "bob")
    try await eventuallyMain { await transport.reads.count == 1 }
    try await eventuallyMain { model.conversations.first(where: { $0.id == "bob" })?.unreadCount == 0 }
    await model.stop()
    await store.stop()
}

@Test @MainActor
func paginatedHistoryMergesThroughStoreWithoutDuplicates() async throws {
    let transport = ChatFakeTransport()
    let newest = chatMessage("m-3", from: "bob", to: "alice", at: "2026-08-16T10:00:03.000Z")
    let middle = chatMessage("m-2", from: "alice", to: "bob", at: "2026-08-16T10:00:02.000Z")
    let oldest = chatMessage("m-1", from: "bob", to: "alice", at: "2026-08-16T10:00:01.000Z")
    let history = PagedHistory([[newest, middle], [oldest, middle]])
    let credentials = ChatFakeCredentials()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: credentials,
        historyService: history,
        currentUserID: "alice"
    )
    await store.replaceSocialSnapshot(contacts: [contact("bob", "Bob")], incomingRequests: [])
    let model = ChatViewModel(
        historyService: history,
        credentials: credentials,
        store: store,
        currentUserID: "alice",
        pageSize: 2
    )
    await model.start()
    await model.select(peerID: "bob")

    #expect(model.messages.map(\.serverID) == ["m-2", "m-3"])
    #expect(model.hasMoreHistory)
    await model.loadOlder()
    try await eventuallyMain { model.messages.count == 3 }
    #expect(model.messages.map(\.serverID) == ["m-1", "m-2", "m-3"])
    #expect(model.hasMoreHistory)
    let calls = await history.recordedCalls()
    #expect(calls[1].1 == middle.createdAt)
    await model.stop()
    await store.stop()
}

@Test @MainActor
func composerDebouncesTypingStopAndCleansUp() async throws {
    let transport = ChatFakeTransport()
    let history = PagedHistory([[]])
    let credentials = ChatFakeCredentials()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: credentials,
        historyService: history,
        currentUserID: "alice"
    )
    await store.replaceSocialSnapshot(contacts: [contact("bob", "Bob")], incomingRequests: [])
    let model = ChatViewModel(
        historyService: history,
        credentials: credentials,
        store: store,
        currentUserID: "alice",
        typingIdleDelay: .milliseconds(25)
    )
    await model.start()
    await model.select(peerID: "bob")

    model.composerDidChange("h")
    model.composerDidChange("he")
    try await eventuallyMain { await transport.typing.count == 2 }
    let events = await transport.typing
    #expect(events[0].0 && events[0].1 == "bob")
    #expect(!events[1].0 && events[1].1 == "bob")
    await model.stop()
    await store.stop()
}
