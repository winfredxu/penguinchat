import Combine
import Foundation

@MainActor
public final class ContactsViewModel: ObservableObject {
    @Published public private(set) var contacts: [Contact] = []
    @Published public private(set) var incomingRequests: [FriendRequest] = []
    @Published public private(set) var connection: RealtimeConnectionState = .disconnected(reason: nil)
    @Published public private(set) var isLoading = false
    @Published public private(set) var isSendingRequest = false
    @Published public private(set) var mutatingRequestIDs: Set<String> = []
    @Published public private(set) var hasLoaded = false
    @Published public var errorMessage: String?
    @Published public var confirmationMessage: String?

    private let service: any ContactsServing
    private let credentials: any RealtimeCredentialProviding
    private let store: RealtimeChatStore
    private var observationTask: Task<Void, Never>?
    private var realtimeRefreshTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var observedSocialRevision = 0

    public init(
        service: any ContactsServing,
        credentials: any RealtimeCredentialProviding,
        store: RealtimeChatStore
    ) {
        self.service = service
        self.credentials = credentials
        self.store = store
    }

    deinit {
        observationTask?.cancel()
        realtimeRefreshTask?.cancel()
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
        await reload()
    }

    public func stop() async {
        loadGeneration += 1
        observationTask?.cancel()
        observationTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        await store.stop()
    }

    public func reload(replacePresence: Bool = false) async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        errorMessage = nil

        do {
            let result = try await withTokenRetry { token in
                let contacts = try await self.service.contacts(accessToken: token)
                let requests = try await self.service.incomingRequests(accessToken: token)
                return (contacts, requests)
            }
            guard generation == loadGeneration else { return }
            await store.replaceSocialSnapshot(
                contacts: result.0,
                incomingRequests: result.1,
                replacePresence: replacePresence
            )
            consume(await store.snapshot())
            hasLoaded = true
        } catch {
            guard generation == loadGeneration else { return }
            errorMessage = Self.message(for: error, fallback: "无法加载联系人，请稍后重试。")
        }

        if generation == loadGeneration { isLoading = false }
    }

    @discardableResult
    public func sendRequest(username: String, message: String?) async -> Bool {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            errorMessage = "请输入对方的企鹅号。"
            return false
        }
        guard username.count <= 32 else {
            errorMessage = "企鹅号不能超过 32 个字符。"
            return false
        }
        guard (message?.count ?? 0) <= 140 else {
            errorMessage = "验证消息不能超过 140 个字符。"
            return false
        }
        guard !isSendingRequest else { return false }

        isSendingRequest = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isSendingRequest = false }
        do {
            _ = try await withTokenRetry { token in
                try await self.service.sendRequest(
                    to: username,
                    message: message?.isEmpty == true ? nil : message,
                    accessToken: token
                )
            }
            confirmationMessage = "好友请求已发送给 @\(username)。"
            return true
        } catch {
            errorMessage = Self.message(for: error, fallback: "好友请求发送失败。")
            return false
        }
    }

    public func accept(_ request: FriendRequest) async {
        await mutate(request, successMessage: "已添加好友。") { token in
            _ = try await self.service.acceptRequest(id: request.id, accessToken: token)
        }
    }

    public func decline(_ request: FriendRequest) async {
        await mutate(request, successMessage: "已拒绝好友请求。") { token in
            try await self.service.declineRequest(id: request.id, accessToken: token)
        }
    }

    private func mutate(
        _ request: FriendRequest,
        successMessage: String,
        operation: @escaping @Sendable (String) async throws -> Void
    ) async {
        guard !mutatingRequestIDs.contains(request.id) else { return }
        loadGeneration += 1 // suppress any older REST response still in flight
        isLoading = false
        mutatingRequestIDs.insert(request.id)
        errorMessage = nil
        confirmationMessage = nil
        defer { mutatingRequestIDs.remove(request.id) }

        do {
            try await withTokenRetry(operation)
            await store.removeIncomingRequest(id: request.id)
            consume(await store.snapshot())
            confirmationMessage = successMessage
            await reload(replacePresence: true)
        } catch {
            errorMessage = Self.message(for: error, fallback: "无法处理好友请求。")
        }
    }

    private func consume(_ snapshot: RealtimeChatSnapshot) {
        contacts = snapshot.contacts
        incomingRequests = snapshot.incomingRequests
        connection = snapshot.connection

        guard snapshot.socialRefreshRevision > observedSocialRevision else { return }
        observedSocialRevision = snapshot.socialRefreshRevision
        guard hasLoaded else { return }
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = Task { [weak self] in
            await self?.reload(replacePresence: true)
        }
    }

    private func withTokenRetry<Value: Sendable>(
        _ operation: @escaping @Sendable (String) async throws -> Value
    ) async throws -> Value {
        guard let token = await credentials.realtimeAccessToken() else {
            throw ContactsViewModelError.signedOut
        }
        do {
            return try await operation(token)
        } catch where Self.isUnauthorized(error) {
            guard let refreshed = try await credentials.refreshRealtimeAccessToken() else {
                throw ContactsViewModelError.signedOut
            }
            return try await operation(refreshed)
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case let APIServiceError.server(status, code, _) = error else { return false }
        return status == 401 || code == "invalid_token" || code == "unauthorized"
    }

    private static func message(for error: Error, fallback: String) -> String {
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return fallback
    }
}

private enum ContactsViewModelError: LocalizedError {
    case signedOut

    var errorDescription: String? { "登录已失效，请重新登录。" }
}
