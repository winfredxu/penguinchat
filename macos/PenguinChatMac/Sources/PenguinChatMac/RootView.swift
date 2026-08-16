import PenguinChatCore
import PenguinChatSocketIO
import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
    @EnvironmentObject private var bus: AppCommandBus
    @StateObject private var authentication: AuthenticationModel

    init(environment: AppEnvironment) {
        self.environment = environment
        _authentication = StateObject(wrappedValue: AuthenticationModel(environment: environment))
    }

    var body: some View {
        Group {
            switch authentication.phase {
            case .restoring:
                ProgressView("正在恢复安全会话…")
                    .accessibilityLabel("正在恢复安全会话")
            case .signedOut:
                AuthenticationView(
                    apiURL: environment.apiBaseURL,
                    model: authentication
                )
            case let .signedIn(session):
                SessionShell(
                    environment: environment,
                    session: session,
                    sessions: authentication.sessions,
                    bus: bus,
                    isSigningOut: authentication.isSubmitting,
                    errorMessage: authentication.errorMessage,
                    onSignOut: { Task { await authentication.logout() } }
                )
                // A new shell (and a new realtime store) per signed-in user id.
                .id(session.user.id)
            }
        }
        .task { await authentication.restore() }
        .onChange(of: authentication.isSignedIn, initial: true) {
            bus.isSignedIn = authentication.isSignedIn
        }
    }
}

private struct AuthenticationView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case login = "登录"
        case register = "注册"

        var id: Self { self }
    }

    let apiURL: URL
    @ObservedObject var model: AuthenticationModel
    @State private var mode: Mode = .login
    @State private var username = ""
    @State private var displayName = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var validationMessage: String?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("🐧")
                    .font(.system(size: 72))
                Text("PenguinChat")
                    .font(.largeTitle.bold())
                Text("原生 macOS 聊天客户端")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("SwiftUI · Keychain 安全会话", systemImage: "lock.shield")
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))

            Form {
                Picker("认证方式", selection: $mode) {
                    ForEach(Mode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                TextField("企鹅号", text: $username)
                    .textContentType(.username)
                    .disabled(model.isSubmitting)

                if mode == .register {
                    TextField("显示名称", text: $displayName)
                        .disabled(model.isSubmitting)
                }

                SecureField("密码", text: $password)
                    .textContentType(mode == .login ? .password : .newPassword)
                    .disabled(model.isSubmitting)

                if mode == .register {
                    SecureField("确认密码", text: $confirmation)
                        .textContentType(.newPassword)
                        .disabled(model.isSubmitting)
                }

                if let message = validationMessage ?? model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }

                Button(action: submit) {
                    HStack {
                        if model.isSubmitting {
                            ProgressView().controlSize(.small)
                        }
                        Text(model.isSubmitting ? "请稍候…" : mode.rawValue)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isSubmitting)
                .keyboardShortcut(.defaultAction)

                Divider()
                LabeledContent("Debug API", value: apiURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding(32)
            .frame(width: 440)
            .onChange(of: mode) {
                validationMessage = nil
                model.errorMessage = nil
            }
        }
    }

    private func submit() {
        validationMessage = validate()
        guard validationMessage == nil else { return }

        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if mode == .login {
                await model.login(username: normalizedUsername, password: password)
            } else {
                await model.register(
                    username: normalizedUsername,
                    displayName: normalizedDisplayName,
                    password: password
                )
            }
        }
    }

    private func validate() -> String? {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty, !password.isEmpty else {
            return "请输入企鹅号和密码。"
        }
        guard mode == .register else { return nil }
        guard (3...32).contains(normalizedUsername.count),
              normalizedUsername.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else {
            return "企鹅号需为 3–32 位字母、数字或下划线。"
        }
        let normalizedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...48).contains(normalizedDisplayName.count) else {
            return "显示名称需为 1–48 个字符。"
        }
        guard (6...128).contains(password.count) else {
            return "密码需为 6–128 个字符。"
        }
        guard password == confirmation else {
            return "两次输入的密码不一致。"
        }
        return nil
    }
}

private struct SessionShell: View {
    private typealias Destination = SidebarDestination

    let session: AuthenticatedSession
    let isSigningOut: Bool
    let errorMessage: String?
    let onSignOut: () -> Void
    @EnvironmentObject private var bus: AppCommandBus
    @Environment(\.controlActiveState) private var controlActiveState
    @StateObject private var model: ContactsViewModel
    @StateObject private var chat: ChatViewModel
    @StateObject private var notifications: NotificationCoordinator
    @State private var planner = NotificationPlanner()
    @State private var destination: Destination? = .conversations
    @State private var selectedContactID: String?
    @State private var selectedConversationID: String?
    @State private var showingSendRequest = false
    @State private var composerFocusRequests = 0

    init(
        environment: AppEnvironment,
        session: AuthenticatedSession,
        sessions: SessionManager,
        bus: AppCommandBus,
        isSigningOut: Bool,
        errorMessage: String?,
        onSignOut: @escaping () -> Void
    ) {
        self.session = session
        self.isSigningOut = isSigningOut
        self.errorMessage = errorMessage
        self.onSignOut = onSignOut
        _notifications = StateObject(wrappedValue: NotificationCoordinator(bus: bus))
        let client = APIClient(baseURL: environment.apiBaseURL)
        let historyService = MessageHistoryService(client: client)
        let store = RealtimeChatStore(
            transport: SocketIORealtimeTransport(serverURL: environment.apiBaseURL),
            credentials: sessions,
            historyService: historyService,
            currentUserID: session.user.id
        )
        _model = StateObject(wrappedValue: ContactsViewModel(
            service: ContactsService(client: client),
            credentials: sessions,
            store: store
        ))
        _chat = StateObject(wrappedValue: ChatViewModel(
            historyService: historyService,
            credentials: sessions,
            store: store,
            currentUserID: session.user.id
        ))
    }

    private var unreadTotal: Int { NotificationPlanner.totalUnread(in: chat.conversations) }

    var body: some View {
        NavigationSplitView {
            List(selection: $destination) {
                Label("消息", systemImage: "bubble.left.and.bubble.right")
                    .badge(unreadTotal)
                    .tag(Destination.conversations)
                    .accessibilityLabel(unreadTotal > 0 ? "消息，\(unreadTotal) 条未读" : "消息")
                Label("联系人", systemImage: "person.2")
                    .badge(model.contacts.count)
                    .tag(Destination.contacts)
                    .accessibilityLabel("联系人，\(model.contacts.count) 位")
                Label("好友请求", systemImage: "person.crop.circle.badge.plus")
                    .badge(model.incomingRequests.count)
                    .tag(Destination.requests)
                    .accessibilityLabel("好友请求，\(model.incomingRequests.count) 条待处理")
            }
            .navigationTitle("PenguinChat")
            .accessibilityLabel("导航")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text(session.user.displayName).font(.headline)
                    Text("@\(session.user.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Label(connectionLabel, systemImage: connectionSymbol)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isRealtimeOffline {
                            Button("重新连接") { Task { await chat.reconnect() } }
                                .buttonStyle(.link)
                                .font(.caption)
                                .accessibilityHint("重新建立实时消息连接")
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("实时连接状态：\(connectionLabel)")
                    Button("退出登录", action: onSignOut)
                        .disabled(isSigningOut)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            Group {
                switch destination ?? .conversations {
                case .conversations:
                    conversationsContent
                case .contacts:
                    contactsContent
                case .requests:
                    requestsContent
                }
            }
            .safeAreaInset(edge: .bottom) { statusBanner }
        } detail: {
            if destination == .conversations {
                ChatDetailView(
                    model: chat,
                    currentUserID: session.user.id,
                    focusRequests: composerFocusRequests
                )
            } else {
                contactDetail
            }
        }
        .toolbar {
            Button {
                showingSendRequest = true
            } label: {
                Label("添加好友", systemImage: "person.badge.plus")
            }
            .help("发送好友请求（⇧⌘N）")
            .accessibilityLabel("添加好友")
        }
        .sheet(isPresented: $showingSendRequest) {
            SendFriendRequestView(model: model, isPresented: $showingSendRequest)
        }
        .task {
            await notifications.requestAuthorizationIfNeeded()
            async let contacts: Void = model.start()
            async let messages: Void = chat.start()
            _ = await (contacts, messages)
        }
        .onDisappear {
            planner.reset()
            notifications.updateBadge(unreadCount: 0)
            Task {
                await chat.stop()
                await model.stop()
            }
        }
        .onReceive(bus.commands) { handle($0) }
        .onChange(of: chat.conversations) { deliverUnreadSurfaces() }
        .onChange(of: isAppActive) {
            guard isAppActive else { return }
            // Coming forward means the banners have been seen.
            notifications.clearDelivered()
            deliverUnreadSurfaces()
        }
        .onChange(of: chat.selectedPeerID, initial: true) {
            bus.hasSelectedConversation = chat.selectedPeerID != nil
            if let peerID = chat.selectedPeerID { notifications.clearDelivered(peerID: peerID) }
        }
    }

    /// The app is "active" for notification purposes only when this window is
    /// the key window — a background window still counts as not being looked at.
    private var isAppActive: Bool { controlActiveState == .key }

    private func deliverUnreadSurfaces() {
        notifications.updateBadge(unreadCount: unreadTotal)
        let pending = planner.plan(
            conversations: chat.conversations,
            currentUserID: session.user.id,
            selectedPeerID: chat.selectedPeerID,
            isAppActive: isAppActive
        )
        notifications.post(pending)
    }

    private func handle(_ command: AppCommand) {
        switch command {
        case .focusComposer:
            destination = .conversations
            composerFocusRequests += 1
        case let .show(target):
            destination = target
        case let .selectAdjacentConversation(offset):
            selectAdjacentConversation(offset: offset)
        case let .openConversation(peerID):
            destination = .conversations
            selectedConversationID = peerID
            Task { await chat.select(peerID: peerID) }
        case .addFriend:
            showingSendRequest = true
        case .reconnect:
            Task { await chat.reconnect() }
        case .refresh:
            Task { await model.reload(replacePresence: true) }
        }
    }

    private func selectAdjacentConversation(offset: Int) {
        let conversations = chat.conversations
        guard !conversations.isEmpty else { return }
        destination = .conversations
        let currentIndex = conversations.firstIndex { $0.id == chat.selectedPeerID }
        // No selection yet: ⇧⌘] opens the first thread, ⇧⌘[ the last.
        let nextIndex = currentIndex.map { index in
            (index + offset + conversations.count) % conversations.count
        } ?? (offset > 0 ? 0 : conversations.count - 1)
        let peerID = conversations[nextIndex].id
        selectedConversationID = peerID
        Task { await chat.select(peerID: peerID) }
    }

    @ViewBuilder
    private var conversationsContent: some View {
        if model.isLoading && !model.hasLoaded {
            ProgressView("正在加载会话…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if chat.conversations.isEmpty {
            ContentUnavailableView(
                "暂无会话",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("添加好友后即可开始聊天。")
            )
        } else {
            List(chat.conversations, selection: $selectedConversationID) { conversation in
                ConversationRow(conversation: conversation, currentUserID: session.user.id)
                    .tag(conversation.id)
            }
            .navigationTitle("消息")
            .onChange(of: selectedConversationID) {
                Task { await chat.select(peerID: selectedConversationID) }
            }
        }
    }

    @ViewBuilder
    private var contactsContent: some View {
        if model.isLoading && !model.hasLoaded {
            ProgressView("正在加载联系人…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasLoaded, model.errorMessage != nil {
            retryView(title: "无法加载联系人", symbol: "wifi.exclamationmark")
        } else if model.contacts.isEmpty {
            ContentUnavailableView(
                "还没有好友",
                systemImage: "person.2.slash",
                description: Text("发送好友请求，接受后会显示在这里。")
            )
        } else {
            List(model.contacts, selection: $selectedContactID) { contact in
                ContactRow(contact: contact).tag(contact.id)
            }
            .navigationTitle("联系人")
            .refreshable { await model.reload(replacePresence: true) }
        }
    }

    @ViewBuilder
    private var requestsContent: some View {
        if model.isLoading && !model.hasLoaded {
            ProgressView("正在加载好友请求…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !model.hasLoaded, model.errorMessage != nil {
            retryView(title: "无法加载好友请求", symbol: "arrow.clockwise.circle")
        } else if model.incomingRequests.isEmpty {
            ContentUnavailableView(
                "暂无好友请求",
                systemImage: "person.crop.circle.badge.checkmark",
                description: Text("新的请求会实时出现在这里。")
            )
        } else {
            List(model.incomingRequests) { request in
                FriendRequestRow(
                    request: request,
                    isMutating: model.mutatingRequestIDs.contains(request.id),
                    accept: { Task { await model.accept(request) } },
                    decline: { Task { await model.decline(request) } }
                )
            }
            .navigationTitle("好友请求")
            .refreshable { await model.reload(replacePresence: true) }
        }
    }

    @ViewBuilder
    private var contactDetail: some View {
        if let contact = model.contacts.first(where: { $0.id == selectedContactID }) {
            VStack(spacing: 14) {
                Text(String(contact.displayName.prefix(1)).uppercased())
                    .font(.system(size: 42, weight: .semibold))
                    .frame(width: 88, height: 88)
                    .background(Color.accentColor.opacity(0.18), in: Circle())
                Text(contact.displayName).font(.title2.bold())
                Text("@\(contact.username)").foregroundStyle(.secondary)
                Label(contact.presence.label, systemImage: contact.presence.symbol)
                    .foregroundStyle(contact.presence.color)
                if let signature = contact.signature, !signature.isEmpty {
                    Text(signature).foregroundStyle(.secondary)
                }
            }
            .padding(36)
        } else {
            ContentUnavailableView(
                "选择一位好友",
                systemImage: "person.crop.circle",
                description: Text("查看在线状态和个人资料。")
            )
        }
    }

    @ViewBuilder
    private var statusBanner: some View {
        if let message = model.errorMessage ?? errorMessage {
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Spacer()
                Button("重试") { Task { await model.reload(replacePresence: true) } }
            }
            .font(.callout)
            .padding(10)
            .background(.bar)
        } else if let message = model.confirmationMessage {
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private func retryView(title: String, symbol: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(model.errorMessage ?? "请检查网络后重试。")
        } actions: {
            Button("重试") { Task { await model.reload(replacePresence: true) } }
                .buttonStyle(.borderedProminent)
        }
    }

    private var connectionLabel: String {
        switch model.connection {
        case .connected: "实时在线"
        case .connecting, .reconnecting: "正在连接"
        case .authenticationFailed: "登录已失效"
        case .disconnected, .failed: "实时连接离线"
        }
    }

    private var connectionSymbol: String {
        if case .connected = model.connection { return "bolt.horizontal.circle.fill" }
        return "bolt.slash.circle"
    }

    /// Offer manual reconnect only when waiting will not fix it on its own —
    /// `.connecting`/`.reconnecting` still have Socket.IO backoff running.
    private var isRealtimeOffline: Bool {
        switch model.connection {
        case .disconnected, .failed, .authenticationFailed: true
        case .connected, .connecting, .reconnecting: false
        }
    }
}

private struct ConversationRow: View {
    let conversation: ConversationSummary
    let currentUserID: String

    var body: some View {
        HStack(spacing: 11) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(conversation.peer.displayName.prefix(1)).uppercased())
                    .font(.headline)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.16), in: Circle())
                Circle()
                    .fill(conversation.peer.presence.color)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(conversation.peer.displayName).font(.headline)
                    Spacer()
                    if let message = conversation.lastMessage {
                        Text(message.createdAt.chatTime)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if let message = conversation.lastMessage {
                        Text(message.senderID == currentUserID ? "我：\(message.body)" : message.body)
                            .lineLimit(1)
                    } else {
                        Text("开始聊天")
                    }
                    Spacer()
                    if conversation.unreadCount > 0 {
                        Text(String(min(conversation.unreadCount, 99)))
                            .font(.caption2.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.red, in: Capsule())
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [conversation.peer.displayName, conversation.peer.presence.label]
        if conversation.unreadCount > 0 { parts.append("\(conversation.unreadCount) 条未读") }
        if let message = conversation.lastMessage {
            parts.append(message.senderID == currentUserID ? "我：\(message.body)" : message.body)
        }
        return parts.joined(separator: "，")
    }
}

private struct ChatDetailView: View {
    @ObservedObject var model: ChatViewModel
    let currentUserID: String
    /// Incremented by the ⌘L menu command; the value itself carries no meaning.
    let focusRequests: Int
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        Group {
            if let conversation = model.selectedConversation {
                VStack(spacing: 0) {
                    header(conversation)
                    Divider()
                    timeline
                    Divider()
                    composer
                }
            } else {
                ContentUnavailableView(
                    "选择一个会话",
                    systemImage: "bubble.left",
                    description: Text("从消息列表选择好友开始聊天。")
                )
            }
        }
        .onChange(of: focusRequests) { composerFocused = true }
        .onChange(of: model.selectedPeerID) { draft = "" }
    }

    private func header(_ conversation: ConversationSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.peer.displayName).font(.headline)
                Text(model.isPeerTyping ? "正在输入…" : conversation.peer.presence.label)
                    .font(.caption)
                    .foregroundStyle(model.isPeerTyping ? Color.accentColor : .secondary)
            }
            Spacer()
            if case .connected = model.connection {
                Label("实时在线", systemImage: "bolt.fill").font(.caption).foregroundStyle(.green)
            } else {
                Label("连接中断", systemImage: "bolt.slash").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var timeline: some View {
        if model.isLoadingHistory && model.messages.isEmpty {
            ProgressView("正在加载聊天记录…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.messages.isEmpty {
            ContentUnavailableView {
                Label("无法加载聊天记录", systemImage: "wifi.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("重试") {
                    guard let peerID = model.selectedConversation?.id else { return }
                    Task {
                        await model.select(peerID: nil)
                        await model.select(peerID: peerID)
                    }
                }
            }
        } else if model.messages.isEmpty {
            ContentUnavailableView(
                "还没有消息",
                systemImage: "hand.wave",
                description: Text("发一条消息打个招呼吧。")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 9) {
                        if model.hasMoreHistory {
                            Button(model.isLoadingOlder ? "加载中…" : "加载更早消息") {
                                Task { await model.loadOlder() }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .disabled(model.isLoadingOlder)
                            .padding(.vertical, 8)
                        }
                        ForEach(model.messages) { message in
                            MessageBubble(
                                message: message,
                                isMine: message.senderID == currentUserID,
                                retry: {
                                    if let clientID = message.clientMessageID {
                                        Task { await model.retry(clientMessageID: clientID) }
                                    }
                                }
                            )
                            .id(message.id)
                        }
                    }
                    .padding(16)
                }
                .onChange(of: model.messages.last?.id) {
                    guard let id = model.messages.last?.id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onAppear {
                    if let id = model.messages.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    composerFocused = true
                }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(alignment: .bottom, spacing: 10) {
                TextField("输入消息", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.roundedBorder)
                    .focused($composerFocused)
                    .onChange(of: draft) { model.composerDidChange(draft) }
                    .onSubmit { submit() }
                    .accessibilityLabel("消息输入框")
                    .accessibilityHint("按回车发送，⌘L 可随时聚焦")
                Button(action: submit) {
                    Image(systemName: "paperplane.fill")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("发送消息（⌘⏎）")
                .accessibilityLabel("发送消息")
            }
            if draft.count > 3_600 {
                Text("\(draft.count)/4000")
                    .font(.caption2)
                    .foregroundStyle(draft.count > 4_000 ? .red : .secondary)
            }
        }
        .padding(12)
    }

    private var canSend: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && draft.count <= 4_000
    }

    private func submit() {
        guard canSend else { return }
        let body = draft
        draft = ""
        Task {
            if !(await model.send(body)) { draft = body }
            composerFocused = true
        }
    }
}

private struct MessageBubble: View {
    let message: ReconciledMessage
    let isMine: Bool
    let retry: () -> Void

    var body: some View {
        HStack {
            if isMine { Spacer(minLength: 80) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(message.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isMine ? Color.accentColor : Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(isMine ? Color.white : Color.primary)
                HStack(spacing: 5) {
                    Text(message.createdAt.chatTime)
                    if isMine { status }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if !isMine { Spacer(minLength: 80) }
        }
        // One bubble reads as one element: sender, text, time, delivery state.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        var parts = [isMine ? "我发送" : "对方发送", message.body, message.createdAt.chatTime]
        if isMine {
            switch message.outboundState {
            case .pending: parts.append("发送中")
            case .failed: parts.append("发送失败")
            case .sent:
                if message.readAt != nil { parts.append("已读") }
                else if message.deliveredAt != nil { parts.append("已送达") }
                else { parts.append("已发送") }
            }
        }
        return parts.joined(separator: "，")
    }

    @ViewBuilder
    private var status: some View {
        switch message.outboundState {
        case .pending:
            Label("发送中", systemImage: "clock")
        case let .failed(reason):
            Button(action: retry) {
                Label("发送失败，重试", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help(reason)
        case .sent:
            if message.readAt != nil {
                Label("已读", systemImage: "checkmark.circle.fill")
            } else if message.deliveredAt != nil {
                Label("已送达", systemImage: "checkmark.circle")
            } else {
                Label("已发送", systemImage: "checkmark")
            }
        }
    }
}

private struct ContactRow: View {
    let contact: Contact

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(contact.displayName.prefix(1)).uppercased())
                    .font(.headline)
                    .frame(width: 38, height: 38)
                    .background(Color.accentColor.opacity(0.16), in: Circle())
                Circle()
                    .fill(contact.presence.color)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName).font(.headline)
                Text("@\(contact.username) · \(contact.presence.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

private struct FriendRequestRow: View {
    let request: FriendRequest
    let isMutating: Bool
    let accept: () -> Void
    let decline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(request.fromDisplayName ?? request.fromUsername ?? "新用户")
                .font(.headline)
            if let username = request.fromUsername { Text("@\(username)").foregroundStyle(.secondary) }
            if let message = request.message, !message.isEmpty { Text(message).font(.callout) }
            HStack {
                Button("接受", action: accept).buttonStyle(.borderedProminent)
                Button("拒绝", action: decline)
                if isMutating { ProgressView().controlSize(.small) }
            }
            .disabled(isMutating)
        }
        .padding(.vertical, 5)
    }
}

private struct SendFriendRequestView: View {
    @ObservedObject var model: ContactsViewModel
    @Binding var isPresented: Bool
    @State private var username = ""
    @State private var message = ""

    var body: some View {
        Form {
            TextField("对方的企鹅号", text: $username)
            TextField("验证消息（可选）", text: $message)
            Text("\(message.count)/140").font(.caption).foregroundStyle(message.count > 140 ? .red : .secondary)
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Button("取消") { isPresented = false }
                Spacer()
                Button(model.isSendingRequest ? "发送中…" : "发送请求") {
                    Task {
                        if await model.sendRequest(username: username, message: message) {
                            isPresented = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isSendingRequest || username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || message.count > 140)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 420)
    }
}

private extension Presence {
    var label: String {
        switch self { case .online: "在线"; case .away: "离开"; case .offline: "离线" }
    }

    var symbol: String {
        switch self { case .online: "circle.fill"; case .away: "moon.fill"; case .offline: "circle" }
    }

    var color: Color {
        switch self { case .online: .green; case .away: .orange; case .offline: .secondary }
    }
}

private extension String {
    var chatTime: String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: self) else { return self }
        return date.formatted(date: .omitted, time: .shortened)
    }
}
