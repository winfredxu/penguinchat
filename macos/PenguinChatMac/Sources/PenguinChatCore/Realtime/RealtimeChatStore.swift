import Foundation

public enum OutboundMessageState: Equatable, Sendable {
    case pending
    case sent
    case failed(reason: String)
}

public struct ReconciledMessage: Equatable, Sendable, Identifiable {
    public var id: String { serverID ?? clientMessageID ?? "\(createdAt)|\(senderID)|\(body)" }
    public var serverID: String?
    public var clientMessageID: String?
    public let conversationID: String
    public let senderID: String
    public let recipientID: String
    public let body: String
    public var createdAt: String
    public var deliveredAt: String?
    public var readAt: String?
    public var outboundState: OutboundMessageState

    public init(
        serverID: String? = nil,
        clientMessageID: String? = nil,
        conversationID: String,
        senderID: String,
        recipientID: String,
        body: String,
        createdAt: String,
        deliveredAt: String? = nil,
        readAt: String? = nil,
        outboundState: OutboundMessageState
    ) {
        self.serverID = serverID
        self.clientMessageID = clientMessageID
        self.conversationID = conversationID
        self.senderID = senderID
        self.recipientID = recipientID
        self.body = body
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.outboundState = outboundState
    }
}

public struct RealtimeChatSnapshot: Equatable, Sendable {
    public let connection: RealtimeConnectionState
    public let messages: [ReconciledMessage]
    public let presenceByUserID: [String: Presence]
    public let typingUserIDs: Set<String>
    public let contacts: [Contact]
    public let incomingRequests: [FriendRequest]
    public let socialRefreshRevision: Int

    public init(
        connection: RealtimeConnectionState,
        messages: [ReconciledMessage],
        presenceByUserID: [String: Presence],
        typingUserIDs: Set<String>,
        contacts: [Contact] = [],
        incomingRequests: [FriendRequest] = [],
        socialRefreshRevision: Int = 0
    ) {
        self.connection = connection
        self.messages = messages
        self.presenceByUserID = presenceByUserID
        self.typingUserIDs = typingUserIDs
        self.contacts = contacts
        self.incomingRequests = incomingRequests
        self.socialRefreshRevision = socialRefreshRevision
    }
}

public actor RealtimeChatStore {
    private let transport: any RealtimeTransport
    private let credentials: any RealtimeCredentialProviding
    private let historyService: any MessageHistoryServing
    private let currentUserID: String

    private var connection: RealtimeConnectionState = .disconnected(reason: nil)
    private var messages: [ReconciledMessage] = []
    private var presenceByUserID: [String: Presence] = [:]
    private var contactsByID: [String: Contact] = [:]
    private var incomingRequestsByID: [String: FriendRequest] = [:]
    private var socialRefreshRevision = 0
    private var typingUserIDs: Set<String> = []
    private var typingExpiryTasks: [String: Task<Void, Never>] = [:]
    private var observedPeerIDs: Set<String> = []
    private var bufferedEvents: [RealtimeEvent] = []
    private var isReconciling = false
    private var eventTask: Task<Void, Never>?
    private var reconciliationTask: Task<Void, Never>?
    private var snapshotContinuations: [UUID: AsyncStream<RealtimeChatSnapshot>.Continuation] = [:]
    private let typingTimeout: Duration

    public init(
        transport: any RealtimeTransport,
        credentials: any RealtimeCredentialProviding,
        historyService: any MessageHistoryServing,
        currentUserID: String,
        typingTimeout: Duration = .seconds(4)
    ) {
        self.transport = transport
        self.credentials = credentials
        self.historyService = historyService
        self.currentUserID = currentUserID
        self.typingTimeout = typingTimeout
    }

    deinit {
        eventTask?.cancel()
        reconciliationTask?.cancel()
        for task in typingExpiryTasks.values { task.cancel() }
    }

    public func start() async throws {
        guard eventTask == nil else { return }
        let stream = await transport.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard !Task.isCancelled else { break }
                await self?.receive(event)
            }
        }
        guard let token = await credentials.realtimeAccessToken() else {
            connection = .authenticationFailed
            return
        }
        connection = .connecting
        await transport.connect(accessToken: token)
    }

    /// Manual recovery for the "实时连接离线" banner: re-dials with a fresh token
    /// instead of waiting for Socket.IO's own backoff to run out of attempts.
    public func reconnect() async {
        var candidate = await credentials.realtimeAccessToken()
        if candidate == nil { candidate = try? await credentials.refreshRealtimeAccessToken() }
        guard let token = candidate else {
            connection = .authenticationFailed
            publishSnapshot()
            return
        }
        RedactingLogger.realtime.info("manual reconnect requested")
        connection = .connecting
        publishSnapshot()
        if eventTask == nil {
            let stream = await transport.events()
            eventTask = Task { [weak self] in
                for await event in stream {
                    guard !Task.isCancelled else { break }
                    await self?.receive(event)
                }
            }
        }
        await transport.connect(accessToken: token)
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        reconciliationTask?.cancel()
        reconciliationTask = nil
        for task in typingExpiryTasks.values { task.cancel() }
        typingExpiryTasks.removeAll()
        typingUserIDs.removeAll()
        await transport.disconnect()
        connection = .disconnected(reason: nil)
    }

    public func snapshot() -> RealtimeChatSnapshot {
        RealtimeChatSnapshot(
            connection: connection,
            messages: sortedMessages(),
            presenceByUserID: presenceByUserID,
            typingUserIDs: typingUserIDs,
            contacts: sortedContacts(),
            incomingRequests: sortedIncomingRequests(),
            socialRefreshRevision: socialRefreshRevision
        )
    }

    public func snapshots() -> AsyncStream<RealtimeChatSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: RealtimeChatSnapshot.self)
        snapshotContinuations[id] = continuation
        continuation.yield(snapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotContinuation(id) }
        }
        return stream
    }

    public func replaceSocialSnapshot(
        contacts: [Contact],
        incomingRequests: [FriendRequest],
        replacePresence: Bool = false
    ) {
        contactsByID = Dictionary(contacts.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
        incomingRequestsByID = Dictionary(
            incomingRequests.filter { $0.status == "pending" }.map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        )
        for contact in contacts where replacePresence || presenceByUserID[contact.id] == nil {
            presenceByUserID[contact.id] = contact.presence
        }
        publishSnapshot()
    }

    public func removeIncomingRequest(id: String) {
        incomingRequestsByID[id] = nil
        publishSnapshot()
    }

    public func mergeHistory(_ history: [ChatMessage], peerID: String) {
        observedPeerIDs.insert(peerID)
        for message in history { mergeServerMessage(message) }
        sortInPlace()
        publishSnapshot()
    }

    @discardableResult
    public func send(body: String, to peerID: String, clientMessageID: String = UUID().uuidString) async -> String {
        observedPeerIDs.insert(peerID)
        let now = ISO8601DateFormatter().string(from: Date())
        messages.append(ReconciledMessage(
            clientMessageID: clientMessageID,
            conversationID: localConversationID(with: peerID),
            senderID: currentUserID,
            recipientID: peerID,
            body: body,
            createdAt: now,
            outboundState: .pending
        ))
        sortInPlace()

        do {
            let acknowledgement = try await transport.sendMessage(SendMessageRequest(
                toUserID: peerID,
                body: body,
                clientMessageID: clientMessageID
            ))
            apply(acknowledgement, fallbackClientMessageID: clientMessageID)
        } catch {
            updateOutbound(clientMessageID: clientMessageID, state: .failed(reason: Redaction.describe(error)))
        }
        return clientMessageID
    }

    public func retry(clientMessageID: String) async {
        guard let message = messages.first(where: { $0.clientMessageID == clientMessageID }) else { return }
        updateOutbound(clientMessageID: clientMessageID, state: .pending)
        do {
            let acknowledgement = try await transport.sendMessage(SendMessageRequest(
                toUserID: message.recipientID,
                body: message.body,
                clientMessageID: clientMessageID
            ))
            apply(acknowledgement, fallbackClientMessageID: clientMessageID)
        } catch {
            updateOutbound(clientMessageID: clientMessageID, state: .failed(reason: Redaction.describe(error)))
        }
    }

    public func confirmDelivered(messageID: String) async throws {
        try await transport.confirmDelivered(messageID: messageID)
    }

    public func markRead(peerID: String, upToMessageID: String) async throws {
        try await transport.markRead(peerID: peerID, upToMessageID: upToMessageID)
    }

    /// Marks the visible incoming range locally before emitting the receipt so
    /// unread badges react immediately and remain convergent after refetch.
    public func markVisibleRead(peerID: String, upToMessageID: String) async throws {
        guard let boundary = messages.first(where: { $0.serverID == upToMessageID }) else { return }
        let readAt = ISO8601DateFormatter().string(from: Date())
        for index in messages.indices where
            messages[index].senderID == peerID &&
            messages[index].recipientID == currentUserID &&
            sortKey(messages[index]) <= sortKey(boundary) {
            messages[index].readAt = messages[index].readAt ?? readAt
        }
        publishSnapshot()
        try await transport.markRead(peerID: peerID, upToMessageID: upToMessageID)
    }

    public func setTyping(_ isTyping: Bool, to peerID: String) async throws {
        try await transport.setTyping(isTyping, toUserID: peerID)
    }

    private func receive(_ event: RealtimeEvent) async {
        if isReconciling, case .connection = event {
            // Connection lifecycle must be handled immediately.
        } else if isReconciling {
            bufferedEvents.append(event)
            return
        }

        switch event {
        case let .connection(state):
            connection = state
            switch state {
            case let .connected(isReconnect) where isReconnect:
                socialRefreshRevision += 1
                beginReconnectReconciliation()
            case .authenticationFailed:
                await reauthenticate()
            default:
                break
            }
        case let .presence(update):
            presenceByUserID[update.userID] = update.status
        case let .friendRequest(event):
            incomingRequestsByID[event.request.id] = event.request
            socialRefreshRevision += 1
        case .friendAccepted:
            socialRefreshRevision += 1
        case let .message(event):
            mergeServerMessage(event.message)
            sortInPlace()
            if event.message.recipientID == currentUserID {
                try? await transport.confirmDelivered(messageID: event.message.id)
            }
        case let .delivery(event):
            if let index = messages.firstIndex(where: { $0.serverID == event.messageID }) {
                messages[index].deliveredAt = event.deliveredAt
            }
        case let .read(event):
            markMessagesRead(event)
        case let .typing(event):
            updateTyping(event)
        }
        publishSnapshot()
    }

    private func beginReconnectReconciliation() {
        guard !isReconciling else { return }
        isReconciling = true
        let peerIDs = observedPeerIDs.sorted()
        let credentials = credentials
        let historyService = historyService
        reconciliationTask = Task { [weak self] in
            var snapshots: [[ChatMessage]] = []
            if let token = await credentials.realtimeAccessToken() {
                for peerID in peerIDs {
                    if let history = try? await historyService.history(
                        with: peerID,
                        before: nil,
                        limit: 50,
                        accessToken: token
                    ) {
                        snapshots.append(history)
                    }
                }
            }
            guard !Task.isCancelled else { return }
            await self?.finishReconnectReconciliation(snapshots)
        }
    }

    private func finishReconnectReconciliation(_ snapshots: [[ChatMessage]]) {
        for snapshot in snapshots {
            for message in snapshot { mergeServerMessage(message) }
        }
        isReconciling = false
        reconciliationTask = nil
        let buffered = bufferedEvents
        bufferedEvents.removeAll()
        for event in buffered {
            applyBuffered(event)
            if case let .message(messageEvent) = event,
               messageEvent.message.recipientID == currentUserID {
                let messageID = messageEvent.message.id
                Task { [transport] in try? await transport.confirmDelivered(messageID: messageID) }
            }
        }
        sortInPlace()
        publishSnapshot()
    }

    private func reauthenticate() async {
        do {
            guard let token = try await credentials.refreshRealtimeAccessToken() else { return }
            connection = .connecting
            await transport.connect(accessToken: token)
        } catch {
            connection = .failed(reason: Redaction.describe(error))
        }
    }

    private func applyBuffered(_ event: RealtimeEvent) {
        switch event {
        case let .presence(update): presenceByUserID[update.userID] = update.status
        case let .friendRequest(event):
            incomingRequestsByID[event.request.id] = event.request
            socialRefreshRevision += 1
        case .friendAccepted:
            socialRefreshRevision += 1
        case let .message(event): mergeServerMessage(event.message)
        case let .delivery(event):
            if let index = messages.firstIndex(where: { $0.serverID == event.messageID }) {
                messages[index].deliveredAt = event.deliveredAt
            }
        case let .read(event): markMessagesRead(event)
        case let .typing(event):
            updateTyping(event)
        case .connection: break
        }
    }

    private func mergeServerMessage(_ incoming: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.serverID == incoming.id }) {
            messages[index] = merge(messages[index], with: incoming)
            return
        }
        messages.append(ReconciledMessage(
            serverID: incoming.id,
            conversationID: incoming.conversation,
            senderID: incoming.senderID,
            recipientID: incoming.recipientID,
            body: incoming.body,
            createdAt: incoming.createdAt,
            deliveredAt: incoming.deliveredAt,
            readAt: incoming.readAt,
            outboundState: .sent
        ))
    }

    private func merge(_ local: ReconciledMessage, with server: ChatMessage) -> ReconciledMessage {
        ReconciledMessage(
            serverID: server.id,
            clientMessageID: local.clientMessageID,
            conversationID: server.conversation,
            senderID: server.senderID,
            recipientID: server.recipientID,
            body: server.body,
            createdAt: server.createdAt,
            deliveredAt: server.deliveredAt ?? local.deliveredAt,
            readAt: server.readAt ?? local.readAt,
            outboundState: .sent
        )
    }

    private func apply(_ acknowledgement: SendAcknowledgement, fallbackClientMessageID: String) {
        let clientID = acknowledgement.clientMessageID ?? fallbackClientMessageID
        guard acknowledgement.error == nil,
              let serverID = acknowledgement.id,
              let index = messages.firstIndex(where: { $0.clientMessageID == clientID }) else {
            updateOutbound(clientMessageID: clientID, state: .failed(reason: acknowledgement.error ?? "invalid_ack"))
            return
        }
        messages[index].serverID = serverID
        messages[index].createdAt = acknowledgement.createdAt ?? messages[index].createdAt
        messages[index].outboundState = .sent
        deduplicateServerID(serverID, keeping: index)
        sortInPlace()
    }

    private func updateOutbound(clientMessageID: String, state: OutboundMessageState) {
        guard let index = messages.firstIndex(where: { $0.clientMessageID == clientMessageID }) else { return }
        messages[index].outboundState = state
    }

    private func deduplicateServerID(_ serverID: String, keeping preferredIndex: Int) {
        guard let duplicate = messages.indices.first(where: { $0 != preferredIndex && messages[$0].serverID == serverID }) else { return }
        let merged = messages[duplicate]
        messages[preferredIndex].deliveredAt = messages[preferredIndex].deliveredAt ?? merged.deliveredAt
        messages[preferredIndex].readAt = messages[preferredIndex].readAt ?? merged.readAt
        messages.remove(at: duplicate)
    }

    /// The peer's read receipt is scoped by participant pair, not by
    /// `event.conversationID`: the server derives conversation IDs as a UUID v5
    /// hash, while an optimistically-sent message still carries the local
    /// placeholder from `localConversationID(with:)` and the send
    /// acknowledgement does not return the server's value. Matching on the
    /// boundary message's sender/recipient pair is unambiguous for a
    /// one-to-one conversation and works before any refetch corrects the id.
    private func markMessagesRead(_ event: ReadEvent) {
        guard let boundary = messages.first(where: { $0.serverID == event.upToMessageID }),
              boundary.senderID == currentUserID else { return }
        let peerID = boundary.recipientID
        let readAt = ISO8601DateFormatter().string(from: Date())
        for index in messages.indices where
            messages[index].senderID == currentUserID &&
            messages[index].recipientID == peerID &&
            sortKey(messages[index]) <= sortKey(boundary) {
            messages[index].readAt = messages[index].readAt ?? readAt
        }
    }

    private func updateTyping(_ event: TypingEvent) {
        typingExpiryTasks[event.fromUserID]?.cancel()
        typingExpiryTasks[event.fromUserID] = nil
        guard event.isTyping else {
            typingUserIDs.remove(event.fromUserID)
            return
        }
        typingUserIDs.insert(event.fromUserID)
        let peerID = event.fromUserID
        let timeout = typingTimeout
        typingExpiryTasks[peerID] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await self?.expireTyping(peerID)
        }
    }

    private func expireTyping(_ peerID: String) {
        typingExpiryTasks[peerID] = nil
        guard typingUserIDs.remove(peerID) != nil else { return }
        publishSnapshot()
    }

    private func localConversationID(with peerID: String) -> String {
        [currentUserID, peerID].sorted().joined(separator: ":")
    }

    private func sortedMessages() -> [ReconciledMessage] {
        messages.sorted { sortKey($0) < sortKey($1) }
    }

    private func sortInPlace() { messages = sortedMessages() }

    private func sortKey(_ message: ReconciledMessage) -> String {
        "\(message.createdAt)|\(message.serverID ?? message.clientMessageID ?? "")"
    }

    private func sortedContacts() -> [Contact] {
        contactsByID.values
            .map { $0.withPresence(presenceByUserID[$0.id] ?? $0.presence) }
            .sorted {
                let comparison = $0.displayName.localizedCaseInsensitiveCompare($1.displayName)
                return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
            }
    }

    private func sortedIncomingRequests() -> [FriendRequest] {
        incomingRequestsByID.values.sorted {
            $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt > $1.createdAt
        }
    }

    private func publishSnapshot() {
        let value = snapshot()
        for continuation in snapshotContinuations.values { continuation.yield(value) }
    }

    private func removeSnapshotContinuation(_ id: UUID) {
        snapshotContinuations[id] = nil
    }
}
