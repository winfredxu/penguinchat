import Foundation
import Testing
@testable import PenguinChatCore

private actor MemoryCredentialStore: CredentialStoring {
    var tokens: Tokens?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(tokens: Tokens? = nil) {
        self.tokens = tokens
    }

    func loadTokens() async throws -> Tokens? { tokens }

    func saveTokens(_ tokens: Tokens) async throws {
        self.tokens = tokens
        saveCount += 1
    }

    func deleteTokens() async throws {
        tokens = nil
        deleteCount += 1
    }
}

private actor StubAuthService: AuthServing {
    enum CurrentUserResponse: Sendable {
        case user(User)
        case unauthorized
    }

    let authResult: AuthResult
    let refreshedTokens: Tokens
    var currentUserResponses: [CurrentUserResponse]
    private(set) var refreshInputs: [String] = []

    init(
        authResult: AuthResult,
        refreshedTokens: Tokens,
        currentUserResponses: [CurrentUserResponse] = []
    ) {
        self.authResult = authResult
        self.refreshedTokens = refreshedTokens
        self.currentUserResponses = currentUserResponses
    }

    func login(username: String, password: String) async throws -> AuthResult {
        authResult
    }

    func register(username: String, displayName: String, password: String) async throws -> AuthResult {
        authResult
    }

    func refresh(using refreshToken: String) async throws -> TokenResult {
        refreshInputs.append(refreshToken)
        return TokenResult(tokens: refreshedTokens)
    }

    func currentUser(accessToken: String) async throws -> User {
        guard !currentUserResponses.isEmpty else { return authResult.user }
        switch currentUserResponses.removeFirst() {
        case let .user(user):
            return user
        case .unauthorized:
            throw APIServiceError.server(
                status: 401,
                code: "invalid_token",
                message: "Invalid token"
            )
        }
    }
}

private struct FailingLoginAuthService: AuthServing {
    func login(username: String, password: String) async throws -> AuthResult {
        throw APIServiceError.server(
            status: 401,
            code: "invalid_credentials",
            message: "Invalid username or password"
        )
    }

    func register(username: String, displayName: String, password: String) async throws -> AuthResult {
        throw APIServiceError.server(status: 500, code: "internal", message: "Internal error")
    }

    func refresh(using refreshToken: String) async throws -> TokenResult {
        throw APIServiceError.server(status: 401, code: "invalid_token", message: "Invalid token")
    }

    func currentUser(accessToken: String) async throws -> User {
        throw APIServiceError.server(status: 401, code: "invalid_token", message: "Invalid token")
    }
}

private let testUser = User(
    id: "user-1",
    username: "alice",
    displayName: "Alice",
    avatarURL: nil,
    signature: nil,
    createdAt: "2026-08-15T00:00:00Z"
)
private let initialTokens = Tokens(accessToken: "access-1", refreshToken: "refresh-1")
private let rotatedTokens = Tokens(accessToken: "access-2", refreshToken: "refresh-2")

@Test func successfulLoginPersistsTokensAndCreatesSession() async throws {
    let store = MemoryCredentialStore()
    let auth = StubAuthService(
        authResult: AuthResult(user: testUser, tokens: initialTokens),
        refreshedTokens: rotatedTokens
    )
    let manager = SessionManager(authService: auth, credentialStore: store)

    let session = try await manager.login(username: "alice", password: "secret")

    #expect(session.user == testUser)
    #expect(session.accessToken == "access-1")
    #expect(await store.tokens == initialTokens)
    #expect(await store.saveCount == 1)
}

@Test func successfulRegistrationPersistsTokensAndCreatesSession() async throws {
    let store = MemoryCredentialStore()
    let auth = StubAuthService(
        authResult: AuthResult(user: testUser, tokens: initialTokens),
        refreshedTokens: rotatedTokens
    )
    let manager = SessionManager(authService: auth, credentialStore: store)

    let session = try await manager.register(
        username: "alice",
        displayName: "Alice",
        password: "secret"
    )

    #expect(session.user == testUser)
    #expect(await store.tokens == initialTokens)
}

@Test func failedLoginDoesNotOverwriteSavedTokens() async {
    let store = MemoryCredentialStore(tokens: initialTokens)
    let manager = SessionManager(authService: FailingLoginAuthService(), credentialStore: store)

    await #expect(throws: APIServiceError.server(
        status: 401,
        code: "invalid_credentials",
        message: "Invalid username or password"
    )) {
        try await manager.login(username: "alice", password: "wrong")
    }

    #expect(await store.tokens == initialTokens)
    #expect(await store.saveCount == 0)
}

@Test func restoreRefreshesExpiredAccessTokenAndPersistsRotation() async throws {
    let store = MemoryCredentialStore(tokens: initialTokens)
    let auth = StubAuthService(
        authResult: AuthResult(user: testUser, tokens: initialTokens),
        refreshedTokens: rotatedTokens,
        currentUserResponses: [.unauthorized, .user(testUser)]
    )
    let manager = SessionManager(authService: auth, credentialStore: store)

    let session = try await manager.restore()

    #expect(session?.accessToken == "access-2")
    #expect(await store.tokens == rotatedTokens)
    #expect(await auth.refreshInputs == ["refresh-1"])
}

@Test func invalidRefreshClearsSessionAndReturnsSignedOut() async throws {
    let store = MemoryCredentialStore(tokens: initialTokens)
    let manager = SessionManager(authService: FailingLoginAuthService(), credentialStore: store)

    let session = try await manager.restore()

    #expect(session == nil)
    #expect(await store.tokens == nil)
    #expect(await store.deleteCount == 1)
}

@Test func logoutDeletesCredentialsAndInMemorySession() async throws {
    let store = MemoryCredentialStore()
    let auth = StubAuthService(
        authResult: AuthResult(user: testUser, tokens: initialTokens),
        refreshedTokens: rotatedTokens
    )
    let manager = SessionManager(authService: auth, credentialStore: store)
    _ = try await manager.login(username: "alice", password: "secret")

    try await manager.logout()

    #expect(await store.tokens == nil)
    #expect(await store.deleteCount == 1)
    #expect(await manager.currentSession() == nil)
}
