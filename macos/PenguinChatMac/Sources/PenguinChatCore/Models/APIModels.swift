import Foundation

public struct User: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let displayName: String
    public let avatarURL: String?
    public let signature: String?
    public let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id, username, signature
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
    }
}

public enum Presence: String, Codable, Sendable {
    case online
    case offline
    case away
}

public struct Contact: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let username: String
    public let displayName: String
    public let avatarURL: String?
    public let signature: String?
    public let createdAt: String
    public let presence: Presence

    public init(
        id: String,
        username: String,
        displayName: String,
        avatarURL: String? = nil,
        signature: String? = nil,
        createdAt: String,
        presence: Presence
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.signature = signature
        self.createdAt = createdAt
        self.presence = presence
    }

    public func withPresence(_ presence: Presence) -> Contact {
        Contact(
            id: id,
            username: username,
            displayName: displayName,
            avatarURL: avatarURL,
            signature: signature,
            createdAt: createdAt,
            presence: presence
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, username, signature, presence
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case createdAt = "created_at"
    }
}

public struct FriendRequest: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let fromUser: String
    public let toUser: String
    public let message: String?
    public let status: String
    public let createdAt: String
    public let fromUsername: String?
    public let fromDisplayName: String?

    public init(
        id: String,
        fromUser: String,
        toUser: String,
        message: String? = nil,
        status: String = "pending",
        createdAt: String,
        fromUsername: String? = nil,
        fromDisplayName: String? = nil
    ) {
        self.id = id
        self.fromUser = fromUser
        self.toUser = toUser
        self.message = message
        self.status = status
        self.createdAt = createdAt
        self.fromUsername = fromUsername
        self.fromDisplayName = fromDisplayName
    }

    enum CodingKeys: String, CodingKey {
        case id, message, status
        case fromUser = "from_user"
        case toUser = "to_user"
        case createdAt = "created_at"
        case fromUsername = "from_username"
        case fromDisplayName = "from_display_name"
    }
}

public struct ChatMessage: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let conversation: String
    public let senderID: String
    public let recipientID: String
    public let body: String
    public let createdAt: String
    public let deliveredAt: String?
    public let readAt: String?

    public init(
        id: String,
        conversation: String,
        senderID: String,
        recipientID: String,
        body: String,
        createdAt: String,
        deliveredAt: String? = nil,
        readAt: String? = nil
    ) {
        self.id = id
        self.conversation = conversation
        self.senderID = senderID
        self.recipientID = recipientID
        self.body = body
        self.createdAt = createdAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
    }

    enum CodingKeys: String, CodingKey {
        case id, conversation, body
        case senderID = "sender_id"
        case recipientID = "recipient_id"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case readAt = "read_at"
    }
}

public struct Tokens: Codable, Equatable, Sendable {
    public let accessToken: String
    public let refreshToken: String
}

public struct AuthResult: Codable, Equatable, Sendable {
    public let user: User
    public let tokens: Tokens
}

public struct TokenResult: Codable, Equatable, Sendable {
    public let tokens: Tokens
}

public struct UserEnvelope: Codable, Equatable, Sendable {
    public let user: User
}

public struct MessageHistory: Codable, Equatable, Sendable {
    public let messages: [ChatMessage]
}

public struct FriendRequestEnvelope: Codable, Equatable, Sendable {
    public let request: FriendRequest
}

public struct FriendAccepted: Codable, Equatable, Sendable {
    public let friendID: String

    enum CodingKeys: String, CodingKey {
        case friendID = "friendId"
    }
}

public struct OKResponse: Codable, Equatable, Sendable {
    public let ok: Bool
}

public struct ServerErrorEnvelope: Codable, Equatable, Sendable {
    public let error: String
    public let message: String
}
