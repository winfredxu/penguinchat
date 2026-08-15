import Foundation

public struct AuthenticatedSession: Equatable, Sendable {
    public let user: User
    public let accessToken: String

    public init(user: User, accessToken: String) {
        self.user = user
        self.accessToken = accessToken
    }
}

public actor SessionManager {
    private let authService: any AuthServing
    private let credentialStore: any CredentialStoring
    private var session: AuthenticatedSession?

    public init(
        authService: any AuthServing,
        credentialStore: any CredentialStoring
    ) {
        self.authService = authService
        self.credentialStore = credentialStore
    }

    @discardableResult
    public func login(username: String, password: String) async throws -> AuthenticatedSession {
        let result = try await authService.login(username: username, password: password)
        return try await adopt(user: result.user, tokens: result.tokens)
    }

    @discardableResult
    public func register(
        username: String,
        displayName: String,
        password: String
    ) async throws -> AuthenticatedSession {
        let result = try await authService.register(
            username: username,
            displayName: displayName,
            password: password
        )
        return try await adopt(user: result.user, tokens: result.tokens)
    }

    /// Restores a saved session. An expired access token is refreshed once.
    /// Invalid/revoked refresh credentials are removed; transient failures are
    /// surfaced without deleting the recoverable Keychain session.
    public func restore() async throws -> AuthenticatedSession? {
        guard let tokens = try await credentialStore.loadTokens() else {
            session = nil
            return nil
        }

        do {
            let user = try await authService.currentUser(accessToken: tokens.accessToken)
            let restored = AuthenticatedSession(user: user, accessToken: tokens.accessToken)
            session = restored
            return restored
        } catch where Self.isUnauthorized(error) {
            return try await refresh(tokens: tokens)
        }
    }

    /// Rotates the refresh token and returns a newly authenticated session.
    /// This is also the recovery hook for protected API calls that receive 401.
    public func refreshSession() async throws -> AuthenticatedSession? {
        guard let tokens = try await credentialStore.loadTokens() else {
            session = nil
            return nil
        }
        return try await refresh(tokens: tokens)
    }

    public func currentSession() -> AuthenticatedSession? {
        session
    }

    public func logout() async throws {
        try await credentialStore.deleteTokens()
        session = nil
    }

    private func adopt(user: User, tokens: Tokens) async throws -> AuthenticatedSession {
        try await credentialStore.saveTokens(tokens)
        let authenticated = AuthenticatedSession(user: user, accessToken: tokens.accessToken)
        session = authenticated
        return authenticated
    }

    private func refresh(tokens: Tokens) async throws -> AuthenticatedSession? {
        do {
            let refreshed = try await authService.refresh(using: tokens.refreshToken).tokens
            // Refresh tokens rotate. Persist the new pair before any further
            // request so the revoked old refresh token is never reused.
            try await credentialStore.saveTokens(refreshed)
            let user = try await authService.currentUser(accessToken: refreshed.accessToken)
            let authenticated = AuthenticatedSession(user: user, accessToken: refreshed.accessToken)
            session = authenticated
            return authenticated
        } catch where Self.isUnauthorized(error) {
            try await credentialStore.deleteTokens()
            session = nil
            return nil
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        guard case let APIServiceError.server(status, code, _) = error else {
            return false
        }
        return status == 401 || code == "invalid_token" || code == "unauthorized"
    }
}
