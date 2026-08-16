import Combine
import Foundation

/// Menu items and notification clicks live outside the view that can act on
/// them, so they publish intent here and `SessionShell` subscribes. Keeping it
/// one-way avoids handing the menu a reference to view state that may not exist
/// yet (the shell only exists while signed in).
enum AppCommand: Equatable {
    case focusComposer
    case show(SidebarDestination)
    case selectAdjacentConversation(offset: Int)
    case openConversation(peerID: String)
    case addFriend
    case reconnect
    case refresh
}

enum SidebarDestination: Hashable {
    case conversations
    case contacts
    case requests
}

@MainActor
final class AppCommandBus: ObservableObject {
    /// Drives menu item enablement — commands are meaningless while signed out.
    @Published var isSignedIn = false
    @Published var hasSelectedConversation = false

    let commands = PassthroughSubject<AppCommand, Never>()

    func send(_ command: AppCommand) {
        commands.send(command)
    }
}
