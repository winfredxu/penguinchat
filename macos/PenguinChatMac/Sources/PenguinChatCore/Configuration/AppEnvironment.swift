import Foundation

public struct AppEnvironment: Equatable, Sendable {
    public static let apiURLVariable = "PENGUINCHAT_API_URL"
    public static let local = AppEnvironment(
        apiBaseURL: URL(string: "http://127.0.0.1:3000")!
    )

    public let apiBaseURL: URL
    public var realtimeBaseURL: URL { apiBaseURL }

    public init(apiBaseURL: URL) {
        self.apiBaseURL = apiBaseURL
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppEnvironment {
        guard
            let rawValue = environment[apiURLVariable],
            let url = URL(string: rawValue),
            let scheme = url.scheme,
            ["http", "https"].contains(scheme),
            url.host != nil
        else {
            return .local
        }
        return AppEnvironment(apiBaseURL: url)
    }
}
