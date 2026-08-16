import Foundation
import Testing
@testable import PenguinChatCore

private let me = "user-me"
private let peer = "user-peer"

private func contact(_ id: String, name: String) -> Contact {
    Contact(
        id: id,
        username: name.lowercased(),
        displayName: name,
        createdAt: "2026-08-16T09:00:00Z",
        presence: .online
    )
}

private func incoming(_ serverID: String, body: String, readAt: String? = nil) -> ReconciledMessage {
    ReconciledMessage(
        serverID: serverID,
        conversationID: "conversation",
        senderID: peer,
        recipientID: me,
        body: body,
        createdAt: "2026-08-16T10:00:00Z",
        readAt: readAt,
        outboundState: .sent
    )
}

private func outgoing(_ serverID: String, body: String) -> ReconciledMessage {
    ReconciledMessage(
        serverID: serverID,
        conversationID: "conversation",
        senderID: me,
        recipientID: peer,
        body: body,
        createdAt: "2026-08-16T10:00:00Z",
        outboundState: .sent
    )
}

private func summary(_ message: ReconciledMessage?, unread: Int) -> [ConversationSummary] {
    [ConversationSummary(peer: contact(peer, name: "Peer"), lastMessage: message, unreadCount: unread)]
}

/// The first plan after launch is existing history, so it must stay silent.
@MainActor
private func seeded() -> NotificationPlanner {
    let planner = NotificationPlanner()
    _ = planner.plan(conversations: [], currentUserID: me, selectedPeerID: nil, isAppActive: false)
    return planner
}

@MainActor
@Test func firstProjectionIsTreatedAsHistoryAndNeverNotifies() {
    let planner = NotificationPlanner()
    let plan = planner.plan(
        conversations: summary(incoming("m1", body: "hello"), unread: 1),
        currentUserID: me,
        selectedPeerID: nil,
        isAppActive: false
    )
    #expect(plan.isEmpty)
}

@MainActor
@Test func notifiesForAnUnreadIncomingMessage() {
    let plan = seeded().plan(
        conversations: summary(incoming("m1", body: "hello"), unread: 1),
        currentUserID: me,
        selectedPeerID: nil,
        isAppActive: false
    )
    #expect(plan.map(\.id) == ["m1"])
    #expect(plan.first?.title == "Peer")
    #expect(plan.first?.body == "hello")
    #expect(plan.first?.peerID == peer)
}

@MainActor
@Test func doesNotNotifyTwiceForTheSameMessage() {
    let planner = seeded()
    let conversations = summary(incoming("m1", body: "hello"), unread: 1)
    _ = planner.plan(conversations: conversations, currentUserID: me, selectedPeerID: nil, isAppActive: false)
    let second = planner.plan(conversations: conversations, currentUserID: me, selectedPeerID: nil, isAppActive: false)
    #expect(second.isEmpty)
}

@MainActor
@Test func suppressesNotificationForTheThreadTheUserIsLookingAt() {
    let plan = seeded().plan(
        conversations: summary(incoming("m1", body: "hello"), unread: 1),
        currentUserID: me,
        selectedPeerID: peer,
        isAppActive: true
    )
    #expect(plan.isEmpty)
}

@MainActor
@Test func notifiesForTheSelectedThreadWhenTheAppIsInactive() {
    let plan = seeded().plan(
        conversations: summary(incoming("m1", body: "hello"), unread: 1),
        currentUserID: me,
        selectedPeerID: peer,
        isAppActive: false
    )
    #expect(plan.map(\.id) == ["m1"])
}

/// A suppressed message must not resurface when the app later loses focus.
@MainActor
@Test func aSuppressedMessageIsNotRaisedAfterTheAppDeactivates() {
    let planner = seeded()
    let conversations = summary(incoming("m1", body: "hello"), unread: 1)
    _ = planner.plan(conversations: conversations, currentUserID: me, selectedPeerID: peer, isAppActive: true)
    let afterDeactivate = planner.plan(
        conversations: conversations,
        currentUserID: me,
        selectedPeerID: peer,
        isAppActive: false
    )
    #expect(afterDeactivate.isEmpty)
}

@MainActor
@Test func ignoresOwnMessagesAndAlreadyReadMessages() {
    let planner = seeded()
    #expect(planner.plan(
        conversations: summary(outgoing("m1", body: "mine"), unread: 0),
        currentUserID: me,
        selectedPeerID: nil,
        isAppActive: false
    ).isEmpty)
    #expect(planner.plan(
        conversations: summary(incoming("m2", body: "seen", readAt: "2026-08-16T10:01:00Z"), unread: 0),
        currentUserID: me,
        selectedPeerID: nil,
        isAppActive: false
    ).isEmpty)
}

/// An optimistic row has no server id yet and cannot be identified for dedupe.
@MainActor
@Test func ignoresMessagesWithoutAServerID() {
    let pending = ReconciledMessage(
        clientMessageID: "local-1",
        conversationID: "conversation",
        senderID: peer,
        recipientID: me,
        body: "no id",
        createdAt: "2026-08-16T10:00:00Z",
        outboundState: .pending
    )
    #expect(seeded().plan(
        conversations: summary(pending, unread: 1),
        currentUserID: me,
        selectedPeerID: nil,
        isAppActive: false
    ).isEmpty)
}

@MainActor
@Test func resetAllowsTheNextAccountToNotifyFromScratch() {
    let planner = seeded()
    let conversations = summary(incoming("m1", body: "hello"), unread: 1)
    _ = planner.plan(conversations: conversations, currentUserID: me, selectedPeerID: nil, isAppActive: false)
    planner.reset()
    // Post-reset the first plan is history again, so it takes two passes.
    _ = planner.plan(conversations: [], currentUserID: me, selectedPeerID: nil, isAppActive: false)
    let plan = planner.plan(conversations: conversations, currentUserID: me, selectedPeerID: nil, isAppActive: false)
    #expect(plan.map(\.id) == ["m1"])
}

@Test func badgeLabelClampsAtNinetyNinePlus() {
    #expect(NotificationPlanner.badgeLabel(unreadCount: 0) == nil)
    #expect(NotificationPlanner.badgeLabel(unreadCount: -1) == nil)
    #expect(NotificationPlanner.badgeLabel(unreadCount: 1) == "1")
    #expect(NotificationPlanner.badgeLabel(unreadCount: 99) == "99")
    #expect(NotificationPlanner.badgeLabel(unreadCount: 100) == "99+")
}

@Test func totalUnreadSumsEveryConversation() {
    let conversations = [
        ConversationSummary(peer: contact("a", name: "A"), lastMessage: nil, unreadCount: 2),
        ConversationSummary(peer: contact("b", name: "B"), lastMessage: nil, unreadCount: 3),
    ]
    #expect(NotificationPlanner.totalUnread(in: conversations) == 5)
}
