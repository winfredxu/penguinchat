import PenguinChatCore
import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
    @State private var showingSessionPreview = false

    var body: some View {
        if showingSessionPreview {
            SessionShell(onSignOut: { showingSessionPreview = false })
        } else {
            LoginShell(
                apiURL: environment.apiBaseURL,
                onPreview: { showingSessionPreview = true }
            )
        }
    }
}

private struct LoginShell: View {
    let apiURL: URL
    let onPreview: () -> Void
    @State private var username = ""
    @State private var password = ""

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
                Label("SwiftUI · 无 WebView", systemImage: "macwindow")
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.12))

            VStack(alignment: .leading, spacing: 16) {
                Text("欢迎回来")
                    .font(.title.bold())
                Text("认证接入将在下一阶段启用；当前按钮用于预览会话壳层。")
                    .foregroundStyle(.secondary)
                TextField("企鹅号", text: $username)
                    .textFieldStyle(.roundedBorder)
                SecureField("密码", text: $password)
                    .textFieldStyle(.roundedBorder)
                Button("预览会话") { onPreview() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Divider()
                LabeledContent("Debug API", value: apiURL.absoluteString)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(48)
            .frame(width: 420)
        }
    }
}

private struct SessionShell: View {
    let onSignOut: () -> Void

    var body: some View {
        NavigationSplitView {
            List {
                Label("最近会话", systemImage: "bubble.left.and.bubble.right")
                Label("联系人", systemImage: "person.2")
            }
            .navigationTitle("PenguinChat")
            .toolbar {
                Button("退出预览", action: onSignOut)
            }
        } content: {
            ContentUnavailableView(
                "暂无会话",
                systemImage: "snowflake",
                description: Text("认证完成后，好友和会话会显示在这里。")
            )
            .navigationTitle("会话")
        } detail: {
            ContentUnavailableView(
                "选择一位好友开始聊天",
                systemImage: "message",
                description: Text("消息、输入状态和已读回执将在聊天阶段接入。")
            )
        }
    }
}
