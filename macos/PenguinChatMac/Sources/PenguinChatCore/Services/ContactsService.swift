import Foundation

public protocol ContactsServing: Sendable {
    func contacts(accessToken: String) async throws -> [Contact]
    func incomingRequests(accessToken: String) async throws -> [FriendRequest]
    func sendRequest(
        to username: String,
        message: String?,
        accessToken: String
    ) async throws -> FriendRequest
    func acceptRequest(id: String, accessToken: String) async throws -> String
    func declineRequest(id: String, accessToken: String) async throws
}

public struct ContactsService: ContactsServing, Sendable {
    private let client: APIClient
    private let encoder = JSONEncoder()

    public init(client: APIClient) {
        self.client = client
    }

    public func contacts(accessToken: String) async throws -> [Contact] {
        try await client.request("/contacts", accessToken: accessToken)
    }

    public func incomingRequests(accessToken: String) async throws -> [FriendRequest] {
        try await client.request("/friend-requests", accessToken: accessToken)
    }

    public func sendRequest(
        to username: String,
        message: String?,
        accessToken: String
    ) async throws -> FriendRequest {
        let body = try encoder.encode(SendFriendRequest(username: username, message: message))
        let result: FriendRequestEnvelope = try await client.request(
            "/friend-requests",
            method: .post,
            body: body,
            accessToken: accessToken
        )
        return result.request
    }

    public func acceptRequest(id: String, accessToken: String) async throws -> String {
        let result: FriendAccepted = try await client.request(
            "/friend-requests/\(id)/accept",
            method: .post,
            accessToken: accessToken
        )
        return result.friendID
    }

    public func declineRequest(id: String, accessToken: String) async throws {
        let _: OKResponse = try await client.request(
            "/friend-requests/\(id)/decline",
            method: .post,
            accessToken: accessToken
        )
    }
}

private struct SendFriendRequest: Encodable {
    let username: String
    let message: String?
}
