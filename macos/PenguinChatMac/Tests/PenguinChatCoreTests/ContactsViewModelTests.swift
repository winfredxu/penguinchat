import Foundation
import Testing
@testable import PenguinChatCore

private actor SocialFakeTransport: RealtimeTransport {
    let stream: AsyncStream<RealtimeEvent>
    private let continuation: AsyncStream<RealtimeEvent>.Continuation

    init() { (stream, continuation) = AsyncStream.makeStream(of: RealtimeEvent.self) }
    func events() async -> AsyncStream<RealtimeEvent> { stream }
    func connect(accessToken: String) async {}
    func disconnect() async {}
    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        throw RealtimeTransportError.notConnected
    }
    func confirmDelivered(messageID: String) async throws {}
    func markRead(peerID: String, upToMessageID: String) async throws {}
    func setTyping(_ isTyping: Bool, toUserID: String) async throws {}
    func emit(_ event: RealtimeEvent) { continuation.yield(event) }
}

private actor SocialFakeCredentials: RealtimeCredentialProviding {
    var token = "token"
    func realtimeAccessToken() async -> String? { token }
    func refreshRealtimeAccessToken() async throws -> String? { token }
}

private struct EmptyHistoryService: MessageHistoryServing {
    func history(with peerID: String, before: String?, limit: Int, accessToken: String) async throws -> [ChatMessage] { [] }
}

private actor FakeContactsService: ContactsServing {
    var contactResponses: [[Contact]]
    var requestResponses: [[FriendRequest]]
    var contactsCallCount = 0
    var requestsCallCount = 0
    var sentUsernames: [String] = []
    var acceptedIDs: [String] = []
    var declinedIDs: [String] = []
    private var suspendFirstContacts = false
    private var firstContactsWaiter: CheckedContinuation<Void, Never>?

    init(contactResponses: [[Contact]], requestResponses: [[FriendRequest]]) {
        self.contactResponses = contactResponses
        self.requestResponses = requestResponses
    }

    func suspendFirstContactLoad() { suspendFirstContacts = true }
    func releaseFirstContactLoad() { firstContactsWaiter?.resume(); firstContactsWaiter = nil }

    func contacts(accessToken: String) async throws -> [Contact] {
        let index = contactsCallCount
        contactsCallCount += 1
        let response = contactResponses[min(index, contactResponses.count - 1)]
        if index == 0, suspendFirstContacts {
            await withCheckedContinuation { firstContactsWaiter = $0 }
        }
        return response
    }

    func incomingRequests(accessToken: String) async throws -> [FriendRequest] {
        let index = requestsCallCount
        requestsCallCount += 1
        return requestResponses[min(index, requestResponses.count - 1)]
    }

    func sendRequest(to username: String, message: String?, accessToken: String) async throws -> FriendRequest {
        sentUsernames.append(username)
        return request(id: "sent", from: "me", username: "me")
    }

    func acceptRequest(id: String, accessToken: String) async throws -> String {
        acceptedIDs.append(id)
        return "bob"
    }

    func declineRequest(id: String, accessToken: String) async throws {
        declinedIDs.append(id)
    }
}

private func contact(id: String, name: String, presence: Presence = .offline) -> Contact {
    Contact(
        id: id,
        username: name.lowercased(),
        displayName: name,
        createdAt: "2026-08-16T00:00:00.000Z",
        presence: presence
    )
}

private func request(id: String, from: String, username: String) -> FriendRequest {
    FriendRequest(
        id: id,
        fromUser: from,
        toUser: "me",
        message: "Hi",
        createdAt: "2026-08-16T00:00:00.000Z",
        fromUsername: username,
        fromDisplayName: username.capitalized
    )
}

@MainActor
private func makeModel(
    service: FakeContactsService,
    transport: SocialFakeTransport = SocialFakeTransport()
) -> (ContactsViewModel, SocialFakeTransport) {
    let credentials = SocialFakeCredentials()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: credentials,
        historyService: EmptyHistoryService(),
        currentUserID: "me"
    )
    return (ContactsViewModel(service: service, credentials: credentials, store: store), transport)
}

@MainActor
private func eventually(_ predicate: () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
}

@Test @MainActor func initialLoadPublishesContactsAndIncomingRequests() async {
    let service = FakeContactsService(
        contactResponses: [[contact(id: "bob", name: "Bob")]],
        requestResponses: [[request(id: "r1", from: "alice", username: "alice")]]
    )
    let (model, _) = makeModel(service: service)

    await model.start()

    #expect(model.hasLoaded)
    #expect(model.contacts.map(\.id) == ["bob"])
    #expect(model.incomingRequests.map(\.id) == ["r1"])
    await model.stop()
}

@Test @MainActor func requestMutationsReconcileWithoutDuplicateRows() async {
    let bob = contact(id: "bob", name: "Bob")
    let first = request(id: "r1", from: "bob", username: "bob")
    let second = request(id: "r2", from: "alice", username: "alice")
    let service = FakeContactsService(
        contactResponses: [[], [bob, bob], [bob]],
        requestResponses: [[first, second], [second], []]
    )
    let (model, _) = makeModel(service: service)
    await model.start()

    #expect(await model.sendRequest(username: " carol ", message: "hello"))
    await model.accept(first)
    #expect(model.contacts.map(\.id) == ["bob"])
    #expect(model.incomingRequests.map(\.id) == ["r2"])

    await model.decline(second)
    #expect(model.contacts.map(\.id) == ["bob"])
    #expect(model.incomingRequests.isEmpty)
    #expect(await service.sentUsernames == ["carol"])
    #expect(await service.acceptedIDs == ["r1"])
    #expect(await service.declinedIDs == ["r2"])
    await model.stop()
}

@Test @MainActor func presenceDeltaUpdatesTheCentralContactSnapshot() async throws {
    let service = FakeContactsService(
        contactResponses: [[contact(id: "bob", name: "Bob")]],
        requestResponses: [[]]
    )
    let transport = SocialFakeTransport()
    let (model, _) = makeModel(service: service, transport: transport)
    await model.start()

    await transport.emit(.presence(PresenceUpdate(userID: "bob", status: .away)))
    try await eventually { model.contacts.first?.presence == .away }

    #expect(model.contacts.first?.presence == .away)
    #expect(await service.contactsCallCount == 1)
    await model.stop()
}

@Test @MainActor func reconnectRefetchesAndConvergesPresence() async throws {
    let service = FakeContactsService(
        contactResponses: [
            [contact(id: "bob", name: "Bob", presence: .online)],
            [contact(id: "bob", name: "Bob", presence: .offline)],
        ],
        requestResponses: [[], []]
    )
    let transport = SocialFakeTransport()
    let (model, _) = makeModel(service: service, transport: transport)
    await model.start()

    await transport.emit(.connection(.connected(isReconnect: true)))
    try await eventually { await service.contactsCallCount == 2 && model.contacts.first?.presence == .offline }

    #expect(model.contacts.first?.presence == .offline)
    await model.stop()
}

@Test @MainActor func olderRESTResponseCannotOverwriteNewerLoad() async throws {
    let old = contact(id: "old", name: "Old")
    let newest = contact(id: "new", name: "New")
    let service = FakeContactsService(
        contactResponses: [[old], [newest]],
        requestResponses: [[], []]
    )
    await service.suspendFirstContactLoad()
    let (model, _) = makeModel(service: service)

    let olderLoad = Task { await model.reload() }
    try await eventually { await service.contactsCallCount == 1 }
    await model.reload()
    await service.releaseFirstContactLoad()
    await olderLoad.value

    #expect(model.contacts.map(\.id) == ["new"])
}
