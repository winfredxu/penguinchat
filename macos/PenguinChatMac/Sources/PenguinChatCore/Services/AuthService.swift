import Foundation

public protocol AuthServing: Sendable {
    func login(username: String, password: String) async throws -> AuthResult
    func register(username: String, displayName: String, password: String) async throws -> AuthResult
    func refresh(using refreshToken: String) async throws -> TokenResult
    func currentUser(accessToken: String) async throws -> User
}

public struct AuthService: AuthServing, Sendable {
    private let client: APIClient
    private let encoder = JSONEncoder()

    public init(client: APIClient) {
        self.client = client
    }

    public func login(username: String, password: String) async throws -> AuthResult {
        let body = try encoder.encode(LoginRequest(username: username, password: password))
        return try await client.request("/auth/login", method: .post, body: body)
    }

    public func register(
        username: String,
        displayName: String,
        password: String
    ) async throws -> AuthResult {
        let body = try encoder.encode(
            RegisterRequest(username: username, displayName: displayName, password: password)
        )
        return try await client.request("/auth/register", method: .post, body: body)
    }

    public func refresh(using refreshToken: String) async throws -> TokenResult {
        let body = try encoder.encode(RefreshRequest(refreshToken: refreshToken))
        return try await client.request("/auth/refresh", method: .post, body: body)
    }

    public func currentUser(accessToken: String) async throws -> User {
        let result: UserEnvelope = try await client.request("/me", accessToken: accessToken)
        return result.user
    }
}

private struct LoginRequest: Encodable {
    let username: String
    let password: String
}

private struct RegisterRequest: Encodable {
    let username: String
    let displayName: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case username, password
        case displayName = "display_name"
    }
}

private struct RefreshRequest: Encodable {
    let refreshToken: String
}
