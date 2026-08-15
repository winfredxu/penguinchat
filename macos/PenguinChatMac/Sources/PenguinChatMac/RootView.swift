import PenguinChatCore
import SwiftUI

struct RootView: View {
    let environment: AppEnvironment
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
            case .signedOut:
                AuthenticationView(
                    apiURL: environment.apiBaseURL,
                    model: authentication
                )
            case let .signedIn(session):
                SessionShell(
                    session: session,
                    isSigningOut: authentication.isSubmitting,
                    errorMessage: authentication.errorMessage,
                    onSignOut: { Task { await authentication.logout() } }
                )
            }
        }
        .task { await authentication.restore() }
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
    let session: AuthenticatedSession
    let isSigningOut: Bool
    let errorMessage: String?
    let onSignOut: () -> Void

    var body: some View {
        NavigationSplitView {
            List {
                Label("最近会话", systemImage: "bubble.left.and.bubble.right")
                Label("联系人", systemImage: "person.2")
            }
            .navigationTitle("PenguinChat")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Divider()
                    Text(session.user.displayName).font(.headline)
                    Text("@\(session.user.username)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("退出登录", action: onSignOut)
                        .disabled(isSigningOut)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } content: {
            ContentUnavailableView(
                "暂无会话",
                systemImage: "snowflake",
                description: Text("联系人和会话将在下一阶段显示在这里。")
            )
            .navigationTitle("会话")
        } detail: {
            VStack {
                ContentUnavailableView(
                    "选择一位好友开始聊天",
                    systemImage: "message",
                    description: Text("认证已完成，实时聊天将在下一阶段接入。")
                )
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).font(.callout)
                }
            }
        }
    }
}
