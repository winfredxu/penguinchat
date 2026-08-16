import Foundation

/// Receives presence facts discovered outside the realtime event stream, so the
/// REST contact snapshot and `presence:update` deltas converge in one place.
public protocol PresenceMerging: Sendable {
    func mergePresenceSnapshot(_ presenceByUserID: [String: Presence]) async
}

extension RealtimeChatStore: PresenceMerging {}

/// Supplies the bearer token for contact requests and rotates it once when the
/// server rejects the current one.
public protocol ContactsCredentialProviding: Sendable {
    func contactsAccessToken() async -> String?
    func refreshContactsAccessToken() async throws -> String?
}

extension SessionManager: ContactsCredentialProviding {
    public func contactsAccessToken() -> String? {
        currentSession()?.accessToken
    }

    public func refreshContactsAccessToken() async throws -> String? {
        try await refreshSession()?.accessToken
    }
}

public struct ContactsSnapshot: Equatable, Sendable {
    public let contacts: [Contact]
    public let incomingRequests: [FriendRequest]

    public init(contacts: [Contact], incomingRequests: [FriendRequest]) {
        self.contacts = contacts
        self.incomingRequests = incomingRequests
    }
}

public enum ContactsStoreError: Error, Equatable, Sendable {
    case notAuthenticated
}

/// Owns the contact roster and incoming friend requests. Presence is never
/// cached here: it is forwarded to `PresenceMerging` and read back from the
/// realtime store, so the two views of a user cannot drift.
public actor ContactsStore {
    private let service: any ContactsServing
    private let credentials: any ContactsCredentialProviding
    private let presenceSink: any PresenceMerging

    private var contacts: [Contact] = []
    private var incomingRequests: [FriendRequest] = []
    /// Monotonic token: a reload started earlier must not overwrite newer state
    /// when its response arrives late.
    private var loadGeneration = 0

    public init(
        service: any ContactsServing,
        credentials: any ContactsCredentialProviding,
        presenceSink: any PresenceMerging
    ) {
        self.service = service
        self.credentials = credentials
        self.presenceSink = presenceSink
    }

    public func snapshot() -> ContactsSnapshot {
        ContactsSnapshot(contacts: contacts, incomingRequests: incomingRequests)
    }

    /// Reloads both lists from REST. Returns the applied snapshot, or nil when a
    /// newer load superseded this one.
    @discardableResult
    public func reload() async throws -> ContactsSnapshot? {
        loadGeneration += 1
        let generation = loadGeneration
        let token = try await requireToken()

        let loaded = try await withAuthRetry { accessToken in
            let contacts = try await self.service.contacts(accessToken: accessToken)
            let requests = try await self.service.incomingRequests(accessToken: accessToken)
            return (contacts, requests)
        } initialToken: { token }

        guard generation == loadGeneration else { return nil }
        return await apply(contacts: loaded.0, requests: loaded.1)
    }

    @discardableResult
    public func sendRequest(to username: String, message: String?) async throws -> FriendRequest {
        let token = try await requireToken()
        return try await withAuthRetry { accessToken in
            try await self.service.sendRequest(
                to: username,
                message: message,
                accessToken: accessToken
            )
        } initialToken: { token }
    }

    /// Accepts a request, drops it locally, then reconciles the roster from the
    /// server so the new contact appears exactly once.
    public func acceptRequest(id: String) async throws {
        let token = try await requireToken()
        _ = try await withAuthRetry { accessToken in
            try await self.service.acceptRequest(id: id, accessToken: accessToken)
        } initialToken: { token }
        removeRequest(id: id)
        try await reload()
    }

    public func declineRequest(id: String) async throws {
        let token = try await requireToken()
        try await withAuthRetry { accessToken in
            try await self.service.declineRequest(id: id, accessToken: accessToken)
        } initialToken: { token }
        removeRequest(id: id)
    }

    private func apply(contacts: [Contact], requests: [FriendRequest]) async -> ContactsSnapshot {
        self.contacts = Self.deduplicated(contacts)
        self.incomingRequests = Self.deduplicated(requests)
        await presenceSink.mergePresenceSnapshot(
            Dictionary(self.contacts.map { ($0.id, $0.presence) }, uniquingKeysWith: { _, last in last })
        )
        return snapshot()
    }

    private func removeRequest(id: String) {
        incomingRequests.removeAll { $0.id == id }
    }

    private func requireToken() async throws -> String {
        guard let token = await credentials.contactsAccessToken() else {
            throw ContactsStoreError.notAuthenticated
        }
        return token
    }

    private func withAuthRetry<T>(
        _ operation: (String) async throws -> T,
        initialToken: () -> String
    ) async throws -> T {
        do {
            return try await operation(initialToken())
        } catch where Self.isUnauthorized(error) {
            guard let rotated = try await credentials.refreshContactsAccessToken() else {
                throw ContactsStoreError.notAuthenticated
            }
            return try await operation(rotated)
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case let APIServiceError.server(status, code, _) = error else { return false }
        return status == 401 || code == "invalid_token" || code == "unauthorized"
    }

    private static func deduplicated<T: Identifiable>(_ items: [T]) -> [T] where T.ID == String {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
