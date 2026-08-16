import Foundation
import OSLog

/// Strips credentials out of anything on its way to a log or a UI error string.
///
/// Error values reach us as `String(describing:)` of a transport or URL error,
/// and those descriptions can embed the request that failed — including the
/// `Authorization` header and the handshake `token`. Everything that logs or
/// displays such a string goes through here first.
public enum Redaction: Sendable {
    public static let placeholder = "«redacted»"

    /// Keys whose value is a credential in every payload we send or log.
    static let sensitiveKeys = [
        "token", "accessToken", "access_token", "refreshToken", "refresh_token",
        "password", "authorization", "jti",
    ]

    private static let patterns: [NSRegularExpression] = {
        // Bearer / key-value forms, plus bare JWTs that appear without a key.
        var sources = [
            #"(?i)bearer\s+[A-Za-z0-9\-._~+/]+=*"#,
            #"\beyJ[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]+\.[A-Za-z0-9\-_]*"#,
        ]
        for key in sensitiveKeys {
            // "key": "value" / key=value / key: value
            sources.append(#"(?i)("?\#(key)"?\s*[:=]\s*)("[^"]*"|[^\s,;}&]+)"#)
        }
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    public static func redact(_ text: String) -> String {
        var result = text
        for (index, pattern) in patterns.enumerated() {
            let range = NSRange(result.startIndex..., in: result)
            // The keyed patterns capture the key so it survives; the two
            // unkeyed credential patterns are replaced whole.
            let template = index < 2 ? placeholder : "$1\(placeholder)"
            result = pattern.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: template
            )
        }
        return result
    }

    /// A short, credential-free description safe to log or show to the user.
    public static func describe(_ error: Error) -> String {
        if let api = error as? APIServiceError {
            switch api {
            case let .server(status, code, _): return "server(\(status)/\(code))"
            case .invalidResponse: return "invalid_response"
            case .decoding: return "decoding_failed"
            }
        }
        if let transport = error as? RealtimeTransportError {
            switch transport {
            case .notConnected: return "not_connected"
            case .acknowledgementTimedOut: return "ack_timeout"
            case let .rejected(reason): return "rejected(\(redact(reason)))"
            case .malformedPayload: return "malformed_payload"
            }
        }
        if let urlError = error as? URLError {
            return "url_error(\(urlError.code.rawValue))"
        }
        return redact(String(describing: error))
    }
}

/// Thin `Logger` wrapper so no call site can log a raw error by accident.
public struct RedactingLogger: Sendable {
    public static let realtime = RedactingLogger(category: "realtime")
    public static let session = RedactingLogger(category: "session")
    public static let notifications = RedactingLogger(category: "notifications")

    private let logger: Logger

    public init(subsystem: String = "com.penguinchat.macos", category: String) {
        logger = Logger(subsystem: subsystem, category: category)
    }

    public func info(_ message: String) {
        logger.info("\(Redaction.redact(message), privacy: .public)")
    }

    public func error(_ message: String, error: Error? = nil) {
        let suffix = error.map { " — \(Redaction.describe($0))" } ?? ""
        logger.error("\(Redaction.redact(message) + suffix, privacy: .public)")
    }
}
