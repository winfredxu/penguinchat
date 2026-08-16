import AppKit
import Foundation
import PenguinChatCore
@preconcurrency import UserNotifications

/// Owns the two macOS-visible unread surfaces: Notification Center banners and
/// the Dock badge.
///
/// `UNUserNotificationCenter.current()` traps when the process has no bundle
/// identifier, which is exactly the case for a bare `swift run` of this
/// executable. Every call therefore goes through `center`, which is nil unless
/// we are running from a real `.app` — the Dock badge and the rest of the app
/// keep working either way.
@MainActor
final class NotificationCoordinator: NSObject, ObservableObject {
    /// `userInfo` key carrying the peer whose thread a banner should open.
    fileprivate nonisolated static let peerIDKey = "penguinchat.peerId"

    private let bus: AppCommandBus
    private let logger = RedactingLogger.notifications
    private let center: UNUserNotificationCenter?
    private var didRequestAuthorization = false

    init(bus: AppCommandBus) {
        self.bus = bus
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        super.init()
        center?.delegate = self
    }

    var isAvailable: Bool { center != nil }

    func requestAuthorizationIfNeeded() async {
        guard let center, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            logger.error("notification authorization failed", error: error)
        }
    }

    func post(_ notifications: [MessageNotification]) {
        guard let center, !notifications.isEmpty else { return }
        for notification in notifications {
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.sound = .default
            content.threadIdentifier = notification.peerID
            content.userInfo = [NotificationCoordinator.peerIDKey: notification.peerID]
            let request = UNNotificationRequest(
                identifier: notification.id,
                content: content,
                trigger: nil
            )
            center.add(request) { [logger] error in
                if let error { logger.error("could not deliver notification", error: error) }
            }
        }
    }

    /// `NSApp.dockTile.badgeLabel` is the only unread surface that works without
    /// notification authorization, so it is set unconditionally.
    func updateBadge(unreadCount: Int) {
        NSApp?.dockTile.badgeLabel = NotificationPlanner.badgeLabel(unreadCount: unreadCount)
    }

    /// Called when the app comes forward or a conversation is opened: leaving
    /// read banners in Notification Center makes the badge and the list disagree.
    func clearDelivered(peerID: String? = nil) {
        guard let center else { return }
        guard let peerID else {
            center.removeAllDeliveredNotifications()
            return
        }
        center.getDeliveredNotifications { delivered in
            let ids = delivered
                .filter { $0.request.content.userInfo[NotificationCoordinator.peerIDKey] as? String == peerID }
                .map(\.request.identifier)
            guard !ids.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }


}

extension NotificationCoordinator: UNUserNotificationCenterDelegate {
    /// Without this the system suppresses banners while we are frontmost — but
    /// the planner has already decided the user is not looking at that thread.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let peerID = response.notification.request.content.userInfo[NotificationCoordinator.peerIDKey] as? String
        await MainActor.run {
            NSApp?.activate(ignoringOtherApps: true)
            guard let peerID else { return }
            bus.send(.openConversation(peerID: peerID))
        }
    }
}
