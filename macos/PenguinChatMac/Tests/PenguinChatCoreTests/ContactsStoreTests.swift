import Foundation
import Testing
@testable import PenguinChatCore

private actor FakeContactsService: ContactsServing {
    var contactPages: [[Contact]]
    var requestPages: [[FriendRequest]]
    var sendResult: Result<FriendRequest, Error>
    var acceptError: Error?
    var declineError: Error?

    var contactCalls = 0
    var acceptedIDs: [String] = []
    var declinedIDs: [String] = []
    var sentUsernames: [String] = []
    var usedTokens: [String] = []

    private var gate: CheckedContinuation<Void, Never>?
    private var shouldGateNextContacts = false

    init(
        contactPages: [[Contact]] = [[]],
        requestPages: [[FriendRequest]] = [[]],
        sendResult: Result<FriendRequest, Error> = .success(friendRequest(id: "r-sent"))
    ) {
        self.contactPages = contactPages
        self.requestPages = requestPages
        self.sendResult = sendResult
    }

    func gateNextContactsCall() { shouldGateNextContacts = true }
    func releaseGate() { gate?.resume(); gate = nil }

    func contacts(accessToken: String) async throws -> [Contact] {
        usedTokens.append(accessToken)
        contactCalls += 1
        // Claim this call's page before any suspension so a gated first call
        // still resolves to the page its caller started with.
        let page = contactPages.count > 1 ? contactPages.removeFirst() : (contactPages.first ?? [])
        if shouldGateNextContacts {
            shouldGateNextContacts = false
            await withCheckedContinuation { gate = $0 }
        }
        return page
    }

    func incomingRequests(accessToken: String) async throws -> [FriendRequest] {
        requestPages.count > 1 ? requestPages.removeFirst() : (requestPages.first ?? [])
    }

    func sendRequest(to username: String, message: String?, accessToken: String) async throws -> FriendRequest {
        sentUsernames.append(username)
        usedTokens.append(accessToken)
        return try sendResult.get()
    }

    func acceptRequest(id: String, accessToken: String) async throws -> String {
        usedTokens.append(accessToken)
        if let acceptError {
            self.acceptError = nil
            throw acceptError
        }
        acceptedIDs.append(id)
        return "friend-\(id)"
    }

    func declineRequest(id: String, accessToken: String) async throws {
        if let declineError { throw declineError }
        declinedIDs.append(id)
    }

    func setAcceptError(_ error: Error?) { acceptError = error }
}

private actor FakeContactsCredentials: ContactsCredentialProviding {
    var token: String?
    var rotatedToken: String?
    var refreshCount = 0

    init(token: String?, rotatedToken: String? = nil) {
        self.token = token
        self.rotatedToken = rotatedToken
    }

    func contactsAccessToken() async -> String? { token }

    func refreshContactsAccessToken() async throws -> String? {
        refreshCount += 1
        token = rotatedToken
        return rotatedToken
    }
}

private actor FakePresenceSink: PresenceMerging {
    var merges: [[String: Presence]] = []

    func mergePresenceSnapshot(_ presenceByUserID: [String: Presence]) async {
        merges.append(presenceByUserID)
    }
}

private func contact(
    id: String,
    username: String,
    displayName: String,
    presence: Presence = .offline
) -> Contact {
    let json = """
    {"id":"\(id)","username":"\(username)","display_name":"\(displayName)",
     "avatar_url":null,"signature":null,"created_at":"2026-08-15T10:00:00.000Z",
     "presence":"\(presence.rawValue)"}
    """
    return try! JSONDecoder().decode(Contact.self, from: Data(json.utf8))
}

private func friendRequest(id: String, from: String = "bob") -> FriendRequest {
    let json = """
    {"id":"\(id)","from_user":"\(from)","to_user":"alice","message":"hi",
     "status":"pending","created_at":"2026-08-15T10:00:00.000Z",
     "from_username":"\(from)","from_display_name":"Bob"}
    """
    return try! JSONDecoder().decode(FriendRequest.self, from: Data(json.utf8))
}

private func makeStore(
    service: FakeContactsService,
    credentials: FakeContactsCredentials = FakeContactsCredentials(token: "token"),
    presence: FakePresenceSink = FakePresenceSink()
) -> ContactsStore {
    ContactsStore(service: service, credentials: credentials, presenceSink: presence)
}

@Test func initialLoadPublishesContactsRequestsAndSeedsPresence() async throws {
    let service = FakeContactsService(
        contactPages: [[contact(id: "bob", username: "bob", displayName: "Bob", presence: .online)]],
        requestPages: [[friendRequest(id: "r-1")]]
    )
    let presence = FakePresenceSink()
    let store = makeStore(service: service, presence: presence)

    let snapshot = try await store.reload()

    #expect(snapshot?.contacts.map(\.id) == ["bob"])
    #expect(snapshot?.incomingRequests.map(\.id) == ["r-1"])
    #expect(await presence.merges == [["bob": .online]])
}

@Test func reloadDeduplicatesRepeatedContactsAndRequests() async throws {
    let duplicate = contact(id: "bob", username: "bob", displayName: "Bob")
    let service = FakeContactsService(
        contactPages: [[duplicate, duplicate]],
        requestPages: [[friendRequest(id: "r-1"), friendRequest(id: "r-1")]]
    )
    let store = makeStore(service: service)

    let snapshot = try await store.reload()

    #expect(snapshot?.contacts.count == 1)
    #expect(snapshot?.incomingRequests.count == 1)
}

@Test func acceptingRequestDropsItAndReconcilesRosterWithoutDuplicates() async throws {
    let bob = contact(id: "bob", username: "bob", displayName: "Bob")
    let service = FakeContactsService(
        contactPages: [[], [bob], [bob]],
        requestPages: [[friendRequest(id: "r-1")], [], []]
    )
    let store = makeStore(service: service)
    _ = try await store.reload()

    try await store.acceptRequest(id: "r-1")

    let snapshot = await store.snapshot()
    #expect(await service.acceptedIDs == ["r-1"])
    #expect(snapshot.incomingRequests.isEmpty)
    #expect(snapshot.contacts.map(\.id) == ["bob"])
}

@Test func decliningRequestRemovesItLocally() async throws {
    let service = FakeContactsService(requestPages: [[friendRequest(id: "r-1"), friendRequest(id: "r-2")]])
    let store = makeStore(service: service)
    _ = try await store.reload()

    try await store.declineRequest(id: "r-1")

    #expect(await service.declinedIDs == ["r-1"])
    #expect(await store.snapshot().incomingRequests.map(\.id) == ["r-2"])
}

@Test func staleReloadResponseDoesNotOverwriteNewerState() async throws {
    let stale = contact(id: "stale", username: "stale", displayName: "Stale")
    let fresh = contact(id: "fresh", username: "fresh", displayName: "Fresh")
    let service = FakeContactsService(contactPages: [[stale], [fresh]], requestPages: [[], []])
    let store = makeStore(service: service)

    await service.gateNextContactsCall()
    let slow = Task { try await store.reload() }
    try await eventuallyTrue { await service.contactCalls == 1 }
    // A newer reload starts and finishes while the first is still in flight.
    let fast = try await store.reload()
    await service.releaseGate()
    let slowResult = try await slow.value

    #expect(fast?.contacts.map(\.id) == ["fresh"])
    #expect(slowResult == nil)
    #expect(await store.snapshot().contacts.map(\.id) == ["fresh"])
}

@Test func unauthorizedContactCallRotatesTokenAndRetriesOnce() async throws {
    let service = FakeContactsService(requestPages: [[friendRequest(id: "r-1")]])
    await service.setAcceptError(APIServiceError.server(status: 401, code: "invalid_token", message: "expired"))
    let credentials = FakeContactsCredentials(token: "expired", rotatedToken: "rotated")
    let store = makeStore(service: service, credentials: credentials)
    _ = try await store.reload()

    try await store.acceptRequest(id: "r-1")

    #expect(await credentials.refreshCount == 1)
    #expect(await service.acceptedIDs == ["r-1"])
    #expect(await service.usedTokens.contains("rotated"))
}

@Test func missingSessionSurfacesNotAuthenticated() async {
    let store = makeStore(
        service: FakeContactsService(),
        credentials: FakeContactsCredentials(token: nil)
    )

    await #expect(throws: ContactsStoreError.notAuthenticated) {
        _ = try await store.reload()
    }
}

@Test func realtimePresenceDeltaOverridesRESTSnapshotInStore() async throws {
    let transport = ContactsPresenceTransport()
    let store = RealtimeChatStore(
        transport: transport,
        credentials: ContactsPresenceCredentials(),
        historyService: ContactsPresenceHistory(),
        currentUserID: "alice"
    )
    try await store.start()

    await store.mergePresenceSnapshot(["bob": .offline])
    #expect(await store.presence(for: "bob") == .offline)
    await transport.emit(.presence(PresenceUpdate(userID: "bob", status: .online)))
    try await eventuallyTrue { await store.presence(for: "bob") == .online }

    // A later REST refetch is authoritative again, so both paths converge.
    await store.mergePresenceSnapshot(["bob": .away])
    #expect(await store.presence(for: "bob") == .away)
    await store.stop()
}

private actor ContactsPresenceTransport: RealtimeTransport {
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

private struct ContactsPresenceCredentials: RealtimeCredentialProviding {
    func realtimeAccessToken() async -> String? { "token" }
    func refreshRealtimeAccessToken() async throws -> String? { "token" }
}

private struct ContactsPresenceHistory: MessageHistoryServing {
    func history(with peerID: String, before: String?, limit: Int, accessToken: String) async throws -> [ChatMessage] { [] }
}

private func eventuallyTrue(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<200 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Condition did not become true")
}
