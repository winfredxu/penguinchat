import Foundation
import PenguinChatCore

/// A contact joined with its presence as known by the realtime store.
struct ContactRow: Identifiable, Equatable {
    let contact: Contact
    let presence: Presence

    var id: String { contact.id }
}

@MainActor
final class ContactsModel: ObservableObject {
    enum LoadState: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published private(set) var rows: [ContactRow] = []
    @Published private(set) var incomingRequests: [FriendRequest] = []
    @Published private(set) var loadState: LoadState = .idle
    @Published private(set) var connection: RealtimeConnectionState = .disconnected(reason: nil)
    @Published private(set) var pendingRequestIDs: Set<String> = []
    @Published private(set) var isSendingRequest = false
    @Published var actionMessage: String?

    private let contactsStore: ContactsStore
    private let realtimeStore: RealtimeChatStore
    private var pollTask: Task<Void, Never>?

    init(contactsStore: ContactsStore, realtimeStore: RealtimeChatStore) {
        self.contactsStore = contactsStore
        self.realtimeStore = realtimeStore
    }

    deinit { pollTask?.cancel() }

    func start() async {
        guard pollTask == nil else { return }
        await load()
        // The realtime store is an actor with no publisher; mirror its snapshot
        // so presence, typing, and connection changes reach SwiftUI.
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshFromRealtime()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func load() async {
        loadState = .loading
        do {
            _ = try await contactsStore.reload()
            await refreshFromRealtime()
            loadState = .loaded
        } catch {
            loadState = .failed(Self.message(for: error, fallback: "无法加载联系人，请重试。"))
        }
    }

    func sendRequest(to username: String, message: String?) async -> Bool {
        guard !isSendingRequest else { return false }
        isSendingRequest = true
        actionMessage = nil
        defer { isSendingRequest = false }
        do {
            _ = try await contactsStore.sendRequest(to: username, message: message)
            actionMessage = "好友申请已发送给 @\(username)。"
            return true
        } catch {
            actionMessage = Self.message(for: error, fallback: "发送好友申请失败。")
            return false
        }
    }

    func accept(requestID: String) async {
        await mutateRequest(requestID) {
            try await self.contactsStore.acceptRequest(id: requestID)
        }
    }

    func decline(requestID: String) async {
        await mutateRequest(requestID) {
            try await self.contactsStore.declineRequest(id: requestID)
        }
    }

    private func mutateRequest(
        _ requestID: String,
        operation: () async throws -> Void
    ) async {
        guard !pendingRequestIDs.contains(requestID) else { return }
        pendingRequestIDs.insert(requestID)
        actionMessage = nil
        defer { pendingRequestIDs.remove(requestID) }
        do {
            try await operation()
            await refreshFromRealtime()
        } catch {
            actionMessage = Self.message(for: error, fallback: "操作失败，请重试。")
        }
    }

    private func refreshFromRealtime() async {
        let contacts = await contactsStore.snapshot()
        let realtime = await realtimeStore.snapshot()
        connection = realtime.connection
        incomingRequests = contacts.incomingRequests
        rows = contacts.contacts
            .map { ContactRow(contact: $0, presence: realtime.presenceByUserID[$0.id] ?? $0.presence) }
            .sorted { lhs, rhs in
                if (lhs.presence == .online) != (rhs.presence == .online) {
                    return lhs.presence == .online
                }
                return lhs.contact.displayName.localizedCaseInsensitiveCompare(rhs.contact.displayName) == .orderedAscending
            }
    }

    private static func message(for error: Error, fallback: String) -> String {
        if let serviceError = error as? APIServiceError {
            return serviceError.errorDescription ?? fallback
        }
        if case ContactsStoreError.notAuthenticated = error {
            return "会话已失效，请重新登录。"
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return fallback
    }
}
