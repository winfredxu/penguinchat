import Foundation
import PenguinChatCore
@preconcurrency import SocketIO

public final class SocketIORealtimeTransport: @unchecked Sendable, RealtimeTransport {
    private let serverURL: URL
    private let queue = DispatchQueue(label: "chat.penguin.realtime.socket-io")
    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private var continuation: AsyncStream<RealtimeEvent>.Continuation?
    private var heartbeat: DispatchSourceTimer?
    private var hasConnected = false
    private let decoder = JSONDecoder()

    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    public func events() async -> AsyncStream<RealtimeEvent> {
        AsyncStream { continuation in
            queue.async { [weak self] in
                self?.continuation?.finish()
                self?.continuation = continuation
            }
        }
    }

    public func connect(accessToken: String) async {
        queue.async { [weak self] in self?.replaceSocket(accessToken: accessToken) }
    }

    public func disconnect() async {
        queue.async { [weak self] in
            self?.stopHeartbeat()
            self?.socket?.removeAllHandlers()
            self?.socket?.disconnect()
            self?.socket = nil
            self?.manager = nil
            self?.continuation?.yield(.connection(.disconnected(reason: nil)))
        }
    }

    public func sendMessage(_ request: SendMessageRequest) async throws -> SendAcknowledgement {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let socket, socket.status == .connected else {
                    continuation.resume(throwing: RealtimeTransportError.notConnected)
                    return
                }
                socket.emitWithAck("message:send", self.dictionary(request)).timingOut(after: 10) { data in
                    guard let first = data.first,
                          String(describing: first) != SocketAckStatus.noAck.rawValue else {
                        continuation.resume(throwing: RealtimeTransportError.acknowledgementTimedOut)
                        return
                    }
                    do {
                        continuation.resume(returning: try self.decode(SendAcknowledgement.self, from: first))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    public func confirmDelivered(messageID: String) async throws {
        try await emit("message:delivered", ["messageId": messageID])
    }

    public func markRead(peerID: String, upToMessageID: String) async throws {
        try await emit("message:read", ["peerId": peerID, "upToMessageId": upToMessageID])
    }

    public func setTyping(_ isTyping: Bool, toUserID: String) async throws {
        try await emit(isTyping ? "typing:start" : "typing:stop", ["toUserId": toUserID])
    }

    private func emit(_ event: String, _ payload: [String: String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let socket = self?.socket, socket.status == .connected else {
                    continuation.resume(throwing: RealtimeTransportError.notConnected)
                    return
                }
                socket.emit(event, payload)
                continuation.resume()
            }
        }
    }

    private func replaceSocket(accessToken: String) {
        stopHeartbeat()
        socket?.removeAllHandlers()
        socket?.disconnect()

        let manager = SocketManager(socketURL: serverURL, config: [
            .log(false),
            .compress,
            .handleQueue(queue),
            .reconnects(true),
            .reconnectAttempts(5),
            .reconnectWait(1),
            .reconnectWaitMax(8),
            .randomizationFactor(0.5),
        ])
        let socket = manager.defaultSocket
        self.manager = manager
        self.socket = socket
        registerHandlers(on: socket)
        continuation?.yield(.connection(.connecting))
        // Socket.IO v3+ sends this namespace-connect payload as handshake.auth.
        socket.connect(withPayload: ["token": accessToken])
    }

    private func registerHandlers(on socket: SocketIOClient) {
        socket.on(clientEvent: .connect) { [weak self] _, _ in
            guard let self else { return }
            let reconnect = self.hasConnected
            self.hasConnected = true
            self.continuation?.yield(.connection(.connected(isReconnect: reconnect)))
            self.startHeartbeat()
        }
        socket.on(clientEvent: .disconnect) { [weak self] data, _ in
            self?.stopHeartbeat()
            self?.continuation?.yield(.connection(.disconnected(reason: data.first.map(String.init(describing:)))))
        }
        socket.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            let attempt = data.first as? Int ?? 0
            self?.continuation?.yield(.connection(.reconnecting(attempt: attempt)))
            if attempt >= 5 {
                self?.continuation?.yield(.connection(.failed(reason: "reconnect_attempts_exhausted")))
            }
        }
        socket.on(clientEvent: .error) { [weak self] data, _ in
            let reason = data.map(String.init(describing:)).joined(separator: " ")
            if reason.localizedCaseInsensitiveContains("unauthorized") {
                self?.continuation?.yield(.connection(.authenticationFailed))
            } else {
                self?.continuation?.yield(.connection(.failed(reason: reason)))
            }
        }

        socket.on("presence:update") { [weak self] data, _ in self?.forward(PresenceUpdate.self, data, event: RealtimeEvent.presence) }
        socket.on("friend:request") { [weak self] data, _ in self?.forward(FriendRequestEvent.self, data, event: RealtimeEvent.friendRequest) }
        socket.on("friend:accepted") { [weak self] data, _ in self?.forward(FriendAcceptedEvent.self, data, event: RealtimeEvent.friendAccepted) }
        socket.on("message:new") { [weak self] data, _ in self?.forward(NewMessageEvent.self, data, event: RealtimeEvent.message) }
        socket.on("message:delivered") { [weak self] data, _ in self?.forward(DeliveryEvent.self, data, event: RealtimeEvent.delivery) }
        socket.on("message:read") { [weak self] data, _ in self?.forward(ReadEvent.self, data, event: RealtimeEvent.read) }
        socket.on("typing") { [weak self] data, _ in self?.forward(TypingEvent.self, data, event: RealtimeEvent.typing) }
    }

    private func forward<Value: Decodable>(
        _ type: Value.Type,
        _ data: [Any],
        event: @escaping @Sendable (Value) -> RealtimeEvent
    ) {
        guard let first = data.first else { return }
        do {
            continuation?.yield(event(try decode(type, from: first)))
        } catch {
            continuation?.yield(.connection(.failed(reason: "malformed_event: \(error)")))
        }
    }

    private func startHeartbeat() {
        stopHeartbeat()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 20, repeating: 20)
        timer.setEventHandler { [weak self] in self?.socket?.emit("presence:heartbeat") }
        heartbeat = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func dictionary<Value: Encodable>(_ value: Value) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return [:] }
        return dictionary
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from object: Any) throws -> Value {
        do {
            let data = try JSONSerialization.data(withJSONObject: object)
            return try decoder.decode(type, from: data)
        } catch {
            throw RealtimeTransportError.malformedPayload(String(describing: error))
        }
    }
}
