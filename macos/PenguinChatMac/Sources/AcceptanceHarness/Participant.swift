import Foundation
import PenguinChatCore
import PenguinChatSocketIO

/// One native client: the same `SessionManager` / `RealtimeChatStore` /
/// `ChatViewModel` stack the SwiftUI app builds, wired to the real Socket.IO
/// transport. Driving the view model (not the store directly) is deliberate —
/// it exercises the read-receipt, typing-debounce, and unread-count paths the UI
/// actually depends on.
@MainActor
final class Participant {
    let user: User
    let username: String
    let session: SessionManager
    let store: RealtimeChatStore
    let chat: ChatViewModel
    private let contactsService: ContactsService

    private init(
        user: User,
        username: String,
        session: SessionManager,
        store: RealtimeChatStore,
        chat: ChatViewModel,
        contactsService: ContactsService
    ) {
        self.user = user
        self.username = username
        self.session = session
        self.store = store
        self.chat = chat
        self.contactsService = contactsService
    }

    static func register(
        label: String,
        environment: AppEnvironment,
        password: String
    ) async throws -> Participant {
        let client = APIClient(baseURL: environment.apiBaseURL)
        let session = SessionManager(
            authService: AuthService(client: client),
            credentialStore: InMemoryCredentialStore()
        )
        let username = "qa_\(label)_\(UUID().uuidString.prefix(8).lowercased())"
        let authenticated = try await session.register(
            username: username,
            displayName: "QA \(label.uppercased())",
            password: password
        )

        let history = MessageHistoryService(client: client)
        let store = RealtimeChatStore(
            transport: SocketIORealtimeTransport(serverURL: environment.realtimeBaseURL),
            credentials: session,
            historyService: history,
            currentUserID: authenticated.user.id
        )
        let chat = ChatViewModel(
            historyService: history,
            credentials: session,
            store: store,
            currentUserID: authenticated.user.id
        )
        return Participant(
            user: authenticated.user,
            username: username,
            session: session,
            store: store,
            chat: chat,
            contactsService: ContactsService(client: client)
        )
    }

    var accessToken: String {
        get async { await session.currentSession()?.accessToken ?? "" }
    }

    /// Mirrors what `ContactsStore` does in the app: pull the REST snapshot and
    /// fold it into the single store so presence has one source of truth.
    func refreshContacts() async throws {
        let token = await accessToken
        let contacts = try await contactsService.contacts(accessToken: token)
        let requests = try await contactsService.incomingRequests(accessToken: token)
        await store.replaceSocialSnapshot(
            contacts: contacts,
            incomingRequests: requests,
            replacePresence: true
        )
    }

    func sendFriendRequest(to username: String) async throws -> FriendRequest {
        try await contactsService.sendRequest(to: username, message: nil, accessToken: await accessToken)
    }

    func acceptFriendRequest(id: String) async throws -> String {
        try await contactsService.acceptRequest(id: id, accessToken: await accessToken)
    }

    func incomingRequests() async throws -> [FriendRequest] {
        try await contactsService.incomingRequests(accessToken: await accessToken)
    }
}
