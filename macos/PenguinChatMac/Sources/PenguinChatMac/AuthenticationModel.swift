import Foundation
import PenguinChatCore

@MainActor
final class AuthenticationModel: ObservableObject {
    enum Phase: Equatable {
        case restoring
        case signedOut
        case signedIn(AuthenticatedSession)
    }

    @Published private(set) var phase: Phase = .restoring
    @Published private(set) var isSubmitting = false
    @Published var errorMessage: String?

    let sessions: SessionManager
    private var didRestore = false

    init(environment: AppEnvironment) {
        let service = AuthService(client: APIClient(baseURL: environment.apiBaseURL))
        self.sessions = SessionManager(
            authService: service,
            credentialStore: KeychainTokenStore()
        )
    }

    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        do {
            if let session = try await sessions.restore() {
                phase = .signedIn(session)
            } else {
                phase = .signedOut
            }
        } catch {
            phase = .signedOut
            errorMessage = Self.message(for: error, fallback: "无法恢复会话，请检查网络后重试。")
        }
    }

    func login(username: String, password: String) async {
        await submit {
            try await self.sessions.login(username: username, password: password)
        }
    }

    func register(username: String, displayName: String, password: String) async {
        await submit {
            try await self.sessions.register(
                username: username,
                displayName: displayName,
                password: password
            )
        }
    }

    func logout() async {
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await sessions.logout()
            errorMessage = nil
            phase = .signedOut
        } catch {
            errorMessage = Self.message(for: error, fallback: "无法从 Keychain 清除会话。")
        }
    }

    private func submit(
        operation: () async throws -> AuthenticatedSession
    ) async {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }
        do {
            phase = .signedIn(try await operation())
        } catch {
            errorMessage = Self.message(for: error, fallback: "认证失败，请稍后重试。")
        }
    }

    private static func message(for error: Error, fallback: String) -> String {
        if let serviceError = error as? APIServiceError {
            return serviceError.errorDescription ?? fallback
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return fallback
    }
}
