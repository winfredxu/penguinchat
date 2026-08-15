import Foundation

public protocol MessageHistoryServing: Sendable {
    func history(
        with peerID: String,
        before: String?,
        limit: Int,
        accessToken: String
    ) async throws -> [ChatMessage]
}

public struct MessageHistoryService: MessageHistoryServing, Sendable {
    private let client: APIClient

    public init(client: APIClient) {
        self.client = client
    }

    public func history(
        with peerID: String,
        before: String? = nil,
        limit: Int = 50,
        accessToken: String
    ) async throws -> [ChatMessage] {
        var components = URLComponents()
        components.path = "/conversations/\(peerID)/messages"
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let before {
            components.queryItems?.append(URLQueryItem(name: "before", value: before))
        }
        guard let path = components.string else {
            throw APIServiceError.invalidResponse
        }
        let result: MessageHistory = try await client.request(path, accessToken: accessToken)
        return result.messages
    }
}
