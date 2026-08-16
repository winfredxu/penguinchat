import Foundation

public struct PresenceUpdate: Codable, Equatable, Sendable {
    public let userID: String
    public let status: Presence

    public init(userID: String, status: Presence) {
        self.userID = userID
        self.status = status
    }

    enum CodingKeys: String, CodingKey {
        case userID = "userId"
        case status
    }
}

public struct FriendRequestEvent: Codable, Equatable, Sendable {
    public let request: FriendRequest

    public init(request: FriendRequest) { self.request = request }
}

public struct FriendAcceptedEvent: Codable, Equatable, Sendable {
    public let friendID: String

    public init(friendID: String) { self.friendID = friendID }

    enum CodingKeys: String, CodingKey {
        case friendID = "friendId"
    }
}

public struct NewMessageEvent: Codable, Equatable, Sendable {
    public let message: ChatMessage

    public init(message: ChatMessage) { self.message = message }
}

public struct DeliveryEvent: Codable, Equatable, Sendable {
    public let messageID: String
    public let deliveredAt: String

    public init(messageID: String, deliveredAt: String) {
        self.messageID = messageID
        self.deliveredAt = deliveredAt
    }

    enum CodingKeys: String, CodingKey {
        case messageID = "messageId"
        case deliveredAt = "delivered_at"
    }
}

public struct ReadEvent: Codable, Equatable, Sendable {
    public let conversationID: String
    public let upToMessageID: String

    public init(conversationID: String, upToMessageID: String) {
        self.conversationID = conversationID
        self.upToMessageID = upToMessageID
    }

    enum CodingKeys: String, CodingKey {
        case conversationID = "conversationId"
        case upToMessageID = "upToMessageId"
    }
}

public struct TypingEvent: Codable, Equatable, Sendable {
    public let fromUserID: String
    public let isTyping: Bool

    public init(fromUserID: String, isTyping: Bool) {
        self.fromUserID = fromUserID
        self.isTyping = isTyping
    }

    enum CodingKeys: String, CodingKey {
        case fromUserID = "fromUserId"
        case isTyping
    }
}

public struct SendMessageRequest: Codable, Equatable, Sendable {
    public let toUserID: String
    public let body: String
    public let clientMessageID: String

    public init(toUserID: String, body: String, clientMessageID: String) {
        self.toUserID = toUserID
        self.body = body
        self.clientMessageID = clientMessageID
    }

    enum CodingKeys: String, CodingKey {
        case toUserID = "toUserId"
        case body
        case clientMessageID = "clientMsgId"
    }
}

public struct SendAcknowledgement: Codable, Equatable, Sendable {
    public let id: String?
    public let createdAt: String?
    public let clientMessageID: String?
    public let error: String?

    public init(id: String?, createdAt: String?, clientMessageID: String?, error: String?) {
        self.id = id
        self.createdAt = createdAt
        self.clientMessageID = clientMessageID
        self.error = error
    }

    enum CodingKeys: String, CodingKey {
        case id, error
        case createdAt = "created_at"
        case clientMessageID = "clientMsgId"
    }
}

public enum RealtimeConnectionState: Equatable, Sendable {
    case connecting
    case connected(isReconnect: Bool)
    case disconnected(reason: String?)
    case reconnecting(attempt: Int)
    case authenticationFailed
    case failed(reason: String)
}

public enum RealtimeEvent: Equatable, Sendable {
    case connection(RealtimeConnectionState)
    case presence(PresenceUpdate)
    case friendRequest(FriendRequestEvent)
    case friendAccepted(FriendAcceptedEvent)
    case message(NewMessageEvent)
    case delivery(DeliveryEvent)
    case read(ReadEvent)
    case typing(TypingEvent)
}

public enum RealtimeTransportError: Error, Equatable, Sendable {
    case notConnected
    case acknowledgementTimedOut
    case rejected(String)
    case malformedPayload(String)
}

public protocol RealtimeTransport: Sendable {
    func events() async -> AsyncStream<RealtimeEvent>
    func connect(accessToken: String) async
    func disconnect() async
    func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement
    func confirmDelivered(messageID: String) async throws
    func markRead(peerID: String, upToMessageID: String) async throws
    func setTyping(_ isTyping: Bool, toUserID: String) async throws
}

public protocol RealtimeCredentialProviding: Sendable {
    func realtimeAccessToken() async -> String?
    func refreshRealtimeAccessToken() async throws -> String?
}

extension SessionManager: RealtimeCredentialProviding {
    public func realtimeAccessToken() -> String? {
        currentSession()?.accessToken
    }

    public func refreshRealtimeAccessToken() async throws -> String? {
        try await refreshSession()?.accessToken
    }
}
