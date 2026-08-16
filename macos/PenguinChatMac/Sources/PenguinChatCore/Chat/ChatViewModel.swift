import Combine
import Foundation

public struct ConversationSummary: Equatable, Sendable, Identifiable {
    public var id: String { peer.id }
    public let peer: Contact
    public let lastMessage: ReconciledMessage?
    public let unreadCount: Int

    public init(peer: Contact, lastMessage: ReconciledMessage?, unreadCount: Int) {
        self.peer = peer
        self.lastMessage = lastMessage
        self.unreadCount = unreadCount
    }
}

@MainActor
public final class ChatViewModel: ObservableObject {
    @Published public private(set) var conversations: [ConversationSummary] = []
    @Published public private(set) var messages: [ReconciledMessage] = []
    @Published public private(set) var selectedPeerID: String?
    @Published public private(set) var isLoadingHistory = false
    @Published public private(set) var isLoadingOlder = false
    @Published public private(set) var hasMoreHistory = false
    @Published public private(set) var isPeerTyping = false
    @Published public private(set) var connection: RealtimeConnectionState = .disconnected(reason: nil)
    @Published public var errorMessage: String?

    public var selectedConversation: ConversationSummary? {
        conversations.first { $0.id == selectedPeerID }
    }

    private let historyService: any MessageHistoryServing
    private let credentials: any RealtimeCredentialProviding
    private let store: RealtimeChatStore
    private let currentUserID: String
    private let pageSize: Int
    private let typingIdleDelay: Duration
    private var snapshot = RealtimeChatSnapshot(
        connection: .disconnected(reason: nil),
        messages: [],
        presenceByUserID: [:],
        typingUserIDs: []
    )
    private var observationTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?
    private var typingStopTask: Task<Void, Never>?
    private var loadedPeerIDs: Set<String> = []
    private var historyCursorByPeer: [String: String] = [:]
    private var hasMoreByPeer: [String: Bool] = [:]
    private var typingPeerID: String?
    private var lastReadBoundaryByPeer: [String: String] = [:]

    public init(
        historyService: any MessageHistoryServing,
        credentials: any RealtimeCredentialProviding,
        store: RealtimeChatStore,
        currentUserID: String,
        pageSize: Int = 50,
        typingIdleDelay: Duration = .seconds(1)
    ) {
        self.historyService = historyService
        self.credentials = credentials
        self.store = store
        self.currentUserID = currentUserID
        self.pageSize = pageSize
        self.typingIdleDelay = typingIdleDelay
    }

    deinit {
        observationTask?.cancel()
        historyTask?.cancel()
        typingStopTask?.cancel()
    }

    public func start() async {
        guard observationTask == nil else { return }
        let snapshots = await store.snapshots()
        observationTask = Task { [weak self] in
            for await snapshot in snapshots {
                guard !Task.isCancelled else { return }
                self?.consume(snapshot)
            }
        }
        do {
            try await store.start()
        } catch {
            errorMessage = Self.message(for: error, fallback: "无法启动实时连接。")
        }
    }

    public func stop() async {
        observationTask?.cancel()
        observationTask = nil
        historyTask?.cancel()
        historyTask = nil
        await stopTyping()
    }

    /// Re-dials the realtime connection after an offline stretch.
    public func reconnect() async {
        errorMessage = nil
        await store.reconnect()
    }

    public func select(peerID: String?) async {
        guard peerID != selectedPeerID else { return }
        await stopTyping()
        historyTask?.cancel()
        selectedPeerID = peerID
        rebuildProjection()
        guard let peerID else { return }
        if loadedPeerIDs.contains(peerID) {
            await markLatestIncomingRead()
        } else {
            await loadInitialHistory(for: peerID)
        }
    }

    public func loadOlder() async {
        guard let peerID = selectedPeerID,
              hasMoreByPeer[peerID] == true,
              !isLoadingOlder else { return }
        let before = historyCursorByPeer[peerID]
        isLoadingOlder = true
        errorMessage = nil
        defer { isLoadingOlder = false }
        do {
            let page = try await history(with: peerID, before: before)
            guard selectedPeerID == peerID else { return }
            await store.mergeHistory(page, peerID: peerID)
            updatePagination(page, peerID: peerID)
        } catch is CancellationError {
            return
        } catch {
            errorMessage = Self.message(for: error, fallback: "无法加载更早的消息。")
        }
    }

    public func send(_ body: String) async -> Bool {
        guard let peerID = selectedPeerID else { return false }
        let normalized = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard normalized.count <= 4_000 else {
            errorMessage = "消息不能超过 4000 个字符。"
            return false
        }
        errorMessage = nil
        await stopTyping()
        _ = await store.send(body: normalized, to: peerID)
        return true
    }

    public func retry(clientMessageID: String) async {
        errorMessage = nil
        await store.retry(clientMessageID: clientMessageID)
    }

    public func composerDidChange(_ text: String) {
        guard let peerID = selectedPeerID else { return }
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        typingStopTask?.cancel()
        typingStopTask = nil
        guard hasContent else {
            Task { [weak self] in await self?.stopTyping() }
            return
        }
        if typingPeerID != peerID {
            let previous = typingPeerID
            typingPeerID = peerID
            Task { [weak self] in
                if let previous { try? await self?.store.setTyping(false, to: previous) }
                try? await self?.store.setTyping(true, to: peerID)
            }
        }
        let delay = typingIdleDelay
        typingStopTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.stopTyping()
        }
    }

    private func loadInitialHistory(for peerID: String) async {
        isLoadingHistory = true
        errorMessage = nil
        historyTask = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await self.history(with: peerID, before: nil)
                guard !Task.isCancelled, self.selectedPeerID == peerID else { return }
                await self.store.mergeHistory(page, peerID: peerID)
                self.loadedPeerIDs.insert(peerID)
                self.updatePagination(page, peerID: peerID)
                self.isLoadingHistory = false
                await self.markLatestIncomingRead()
            } catch is CancellationError {
                if self.selectedPeerID == peerID { self.isLoadingHistory = false }
            } catch {
                guard self.selectedPeerID == peerID else { return }
                self.isLoadingHistory = false
                self.errorMessage = Self.message(for: error, fallback: "无法加载聊天记录。")
            }
        }
        await historyTask?.value
        historyTask = nil
    }

    private func history(with peerID: String, before: String?) async throws -> [ChatMessage] {
        try await withTokenRetry { token in
            try await self.historyService.history(
                with: peerID,
                before: before,
                limit: self.pageSize,
                accessToken: token
            )
        }
    }

    private func updatePagination(_ page: [ChatMessage], peerID: String) {
        let oldest = page.min { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if let oldest { historyCursorByPeer[peerID] = oldest.createdAt }
        hasMoreByPeer[peerID] = page.count == pageSize
        if selectedPeerID == peerID { hasMoreHistory = hasMoreByPeer[peerID] ?? false }
    }

    private func consume(_ snapshot: RealtimeChatSnapshot) {
        self.snapshot = snapshot
        connection = snapshot.connection
        rebuildProjection()
        guard selectedPeerID != nil else { return }
        Task { [weak self] in await self?.markLatestIncomingRead() }
    }

    private func rebuildProjection() {
        let contacts = snapshot.contacts
        conversations = contacts.map { contact in
            let peerMessages = snapshot.messages.filter { message in
                (message.senderID == currentUserID && message.recipientID == contact.id) ||
                (message.senderID == contact.id && message.recipientID == currentUserID)
            }
            return ConversationSummary(
                peer: contact,
                lastMessage: peerMessages.last,
                unreadCount: peerMessages.filter {
                    $0.senderID == contact.id && $0.recipientID == currentUserID && $0.readAt == nil
                }.count
            )
        }.sorted { lhs, rhs in
            switch (lhs.lastMessage, rhs.lastMessage) {
            case let (left?, right?):
                let leftKey = (left.createdAt, left.serverID ?? left.clientMessageID ?? "")
                let rightKey = (right.createdAt, right.serverID ?? right.clientMessageID ?? "")
                return leftKey == rightKey ? lhs.id < rhs.id : leftKey > rightKey
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil):
                let comparison = lhs.peer.displayName.localizedCaseInsensitiveCompare(rhs.peer.displayName)
                return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
            }
        }

        guard let peerID = selectedPeerID else {
            messages = []
            isPeerTyping = false
            hasMoreHistory = false
            return
        }
        messages = snapshot.messages.filter {
            ($0.senderID == currentUserID && $0.recipientID == peerID) ||
            ($0.senderID == peerID && $0.recipientID == currentUserID)
        }
        isPeerTyping = snapshot.typingUserIDs.contains(peerID)
        hasMoreHistory = hasMoreByPeer[peerID] ?? false
    }

    private func markLatestIncomingRead() async {
        guard let peerID = selectedPeerID,
              let latest = messages.last(where: {
                  $0.senderID == peerID && $0.recipientID == currentUserID && $0.readAt == nil && $0.serverID != nil
              }),
              let messageID = latest.serverID,
              lastReadBoundaryByPeer[peerID] != messageID else { return }
        lastReadBoundaryByPeer[peerID] = messageID
        try? await store.markVisibleRead(peerID: peerID, upToMessageID: messageID)
    }

    private func stopTyping() async {
        typingStopTask?.cancel()
        typingStopTask = nil
        guard let peerID = typingPeerID else { return }
        typingPeerID = nil
        try? await store.setTyping(false, to: peerID)
    }

    private func withTokenRetry<Value: Sendable>(
        _ operation: @escaping @Sendable (String) async throws -> Value
    ) async throws -> Value {
        guard let token = await credentials.realtimeAccessToken() else { throw ChatViewModelError.signedOut }
        do {
            return try await operation(token)
        } catch where Self.isUnauthorized(error) {
            guard let refreshed = try await credentials.refreshRealtimeAccessToken() else {
                throw ChatViewModelError.signedOut
            }
            return try await operation(refreshed)
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case let APIServiceError.server(status, code, _) = error else { return false }
        return status == 401 || code == "invalid_token" || code == "unauthorized"
    }

    private static func message(for error: Error, fallback: String) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return fallback
    }
}

private enum ChatViewModelError: LocalizedError {
    case signedOut

    var errorDescription: String? { "登录已失效，请重新登录。" }
}
