import Foundation

public struct MessageNotification: Equatable, Sendable, Identifiable {
    public let id: String
    public let peerID: String
    public let title: String
    public let body: String

    public init(id: String, peerID: String, title: String, body: String) {
        self.id = id
        self.peerID = peerID
        self.title = title
        self.body = body
    }
}

/// Decides which incoming messages deserve a system notification and what the
/// Dock badge should read. Kept free of AppKit/UserNotifications so the rules
/// are unit-testable; `NotificationCoordinator` does the delivery.
@MainActor
public final class NotificationPlanner {
    /// Message IDs we have already raised, so a re-published snapshot or a
    /// reconnect refetch cannot notify twice for the same message.
    private var notifiedMessageIDs: Set<String> = []
    /// The first projection after launch or login is existing history, not news.
    private var hasSeeded = false

    public init() {}

    public func plan(
        conversations: [ConversationSummary],
        currentUserID: String,
        selectedPeerID: String?,
        isAppActive: Bool
    ) -> [MessageNotification] {
        let candidates = conversations.compactMap { conversation -> MessageNotification? in
            guard let message = conversation.lastMessage,
                  let messageID = message.serverID,
                  message.senderID == conversation.peer.id,
                  message.recipientID == currentUserID,
                  message.readAt == nil,
                  !notifiedMessageIDs.contains(messageID)
            else { return nil }
            return MessageNotification(
                id: messageID,
                peerID: conversation.peer.id,
                title: conversation.peer.displayName,
                body: message.body
            )
        }

        // Record every candidate as seen, even the ones we suppress: a message
        // the user is already looking at should not pop later on deactivate.
        for candidate in candidates { notifiedMessageIDs.insert(candidate.id) }

        guard hasSeeded else {
            hasSeeded = true
            return []
        }
        return candidates.filter { !(isAppActive && $0.peerID == selectedPeerID) }
    }

    /// Forgets delivery history — used on sign-out so the next account starts clean.
    public func reset() {
        notifiedMessageIDs.removeAll()
        hasSeeded = false
    }

    public nonisolated static func badgeLabel(unreadCount: Int) -> String? {
        switch unreadCount {
        case ..<1: nil
        case 1...99: String(unreadCount)
        default: "99+"
        }
    }

    public nonisolated static func totalUnread(in conversations: [ConversationSummary]) -> Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }
}
