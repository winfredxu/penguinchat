import PenguinChatCore
import SwiftUI

@main
struct PenguinChatMacApp: App {
    private let environment = AppEnvironment.resolve()
    @StateObject private var bus = AppCommandBus()

    var body: some Scene {
        // A single window: the app is one signed-in session, and a second
        // window would mean a second realtime connection for the same account.
        Window("PenguinChat", id: "main") {
            RootView(environment: environment)
                .environmentObject(bus)
                .frame(minWidth: 840, minHeight: 560)
        }
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands { ChatCommands(bus: bus) }
    }
}

private struct ChatCommands: Commands {
    @ObservedObject var bus: AppCommandBus

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("添加好友…") { bus.send(.addFriend) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!bus.isSignedIn)
        }

        CommandMenu("会话") {
            Button("聚焦输入框") { bus.send(.focusComposer) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(!bus.isSignedIn || !bus.hasSelectedConversation)
            Divider()
            Button("下一个会话") { bus.send(.selectAdjacentConversation(offset: 1)) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!bus.isSignedIn)
            Button("上一个会话") { bus.send(.selectAdjacentConversation(offset: -1)) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!bus.isSignedIn)
            Divider()
            Button("刷新联系人与会话") { bus.send(.refresh) }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!bus.isSignedIn)
            Button("重新连接实时服务") { bus.send(.reconnect) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!bus.isSignedIn)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("消息") { bus.send(.show(.conversations)) }
                .keyboardShortcut("1", modifiers: .command)
            Button("联系人") { bus.send(.show(.contacts)) }
                .keyboardShortcut("2", modifiers: .command)
            Button("好友请求") { bus.send(.show(.requests)) }
                .keyboardShortcut("3", modifiers: .command)
        }
    }
}
