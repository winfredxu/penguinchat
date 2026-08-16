import PenguinChatCore
import SwiftUI

struct PresenceBadge: View {
    let presence: Presence

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 9, height: 9)
            .accessibilityLabel(label)
    }

    private var color: Color {
        switch presence {
        case .online: .green
        case .away: .orange
        case .offline: .secondary
        }
    }

    private var label: String {
        switch presence {
        case .online: "在线"
        case .away: "离开"
        case .offline: "离线"
        }
    }
}

struct ContactsView: View {
    @ObservedObject var model: ContactsModel
    @Binding var selectedContactID: String?
    @State private var isPresentingAddContact = false

    var body: some View {
        List(selection: $selectedContactID) {
            if !model.incomingRequests.isEmpty {
                Section("好友申请 (\(model.incomingRequests.count))") {
                    ForEach(model.incomingRequests) { request in
                        FriendRequestRow(
                            request: request,
                            isBusy: model.pendingRequestIDs.contains(request.id),
                            onAccept: { Task { await model.accept(requestID: request.id) } },
                            onDecline: { Task { await model.decline(requestID: request.id) } }
                        )
                    }
                }
            }

            Section("联系人 (\(model.rows.count))") {
                if case let .failed(message) = model.loadState {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("重试") { Task { await model.load() } }
                    }
                } else if model.rows.isEmpty, model.loadState == .loaded {
                    Text("还没有好友，先添加一位吧。")
                        .foregroundStyle(.secondary)
                } else if model.rows.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在加载联系人…").foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(model.rows) { row in
                        ContactRowView(row: row).tag(row.id)
                    }
                }
            }
        }
        .navigationTitle("PenguinChat")
        .toolbar {
            ToolbarItem {
                Button {
                    isPresentingAddContact = true
                } label: {
                    Label("添加好友", systemImage: "person.badge.plus")
                }
                .help("添加好友")
            }
            ToolbarItem {
                Button {
                    Task { await model.load() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .help("刷新联系人")
            }
        }
        .sheet(isPresented: $isPresentingAddContact) {
            AddContactSheet(model: model)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                ConnectionStatusLabel(connection: model.connection)
                if let actionMessage = model.actionMessage {
                    Text(actionMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContactRowView: View {
    let row: ContactRow

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                Text(String(row.contact.displayName.prefix(1)))
                    .font(.headline)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.18), in: .rect(cornerRadius: 8))
                PresenceBadge(presence: row.presence)
                    .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 1.5))
                    .offset(x: 2, y: 2)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.contact.displayName)
                Text("@\(row.contact.username)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FriendRequestRow: View {
    let request: FriendRequest
    let isBusy: Bool
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.fromDisplayName ?? request.fromUsername ?? request.fromUser)
                .font(.headline)
            if let username = request.fromUsername {
                Text("@\(username)").font(.caption).foregroundStyle(.secondary)
            }
            if let message = request.message, !message.isEmpty {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("接受", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                Button("拒绝", action: onDecline)
                    .disabled(isBusy)
                if isBusy { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct ConnectionStatusLabel: View {
    let connection: RealtimeConnectionState

    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .foregroundStyle(tint)
    }

    private var text: String {
        switch connection {
        case .connecting: "正在连接…"
        case let .connected(isReconnect): isReconnect ? "已重新连接" : "已连接"
        case let .reconnecting(attempt): "正在重连（第 \(attempt) 次）…"
        case let .disconnected(reason): reason.map { "已断开：\($0)" } ?? "已断开"
        case .authenticationFailed: "认证失效，正在刷新…"
        case let .failed(reason): "连接失败：\(reason)"
        }
    }

    private var icon: String {
        switch connection {
        case .connected: "bolt.horizontal.circle.fill"
        case .connecting, .reconnecting: "arrow.triangle.2.circlepath"
        default: "bolt.horizontal.circle"
        }
    }

    private var tint: Color {
        switch connection {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .authenticationFailed, .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct AddContactSheet: View {
    @ObservedObject var model: ContactsModel
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var message = ""
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加好友").font(.title2.bold())
            Form {
                TextField("对方企鹅号", text: $username)
                    .disabled(model.isSendingRequest)
                TextField("附加消息（可选）", text: $message, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(model.isSendingRequest)
                if let validationMessage {
                    Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    submit()
                } label: {
                    HStack {
                        if model.isSendingRequest { ProgressView().controlSize(.small) }
                        Text(model.isSendingRequest ? "发送中…" : "发送申请")
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(model.isSendingRequest)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        let normalized = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...32).contains(normalized.count),
              normalized.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") })
        else {
            validationMessage = "企鹅号需为 3–32 位字母、数字或下划线。"
            return
        }
        validationMessage = nil
        let trimmedMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            let sent = await model.sendRequest(
                to: normalized,
                message: trimmedMessage.isEmpty ? nil : trimmedMessage
            )
            if sent { dismiss() }
        }
    }
}
