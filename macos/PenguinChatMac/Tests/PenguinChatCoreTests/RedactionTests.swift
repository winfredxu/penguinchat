import Foundation
import Testing
@testable import PenguinChatCore

private let sampleJWT = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhbGljZSJ9.9Xq-signature_value"

@Test func redactsBearerHeaders() {
    let redacted = Redaction.redact("Authorization: Bearer \(sampleJWT)")
    #expect(!redacted.contains(sampleJWT))
    #expect(redacted.contains(Redaction.placeholder))
}

@Test func redactsTokenAndPasswordFieldsInJSON() {
    let payload = """
    {"token": "\(sampleJWT)", "refresh_token": "r3fr3sh-value", "password": "hunter2", "username": "alice"}
    """
    let redacted = Redaction.redact(payload)
    #expect(!redacted.contains(sampleJWT))
    #expect(!redacted.contains("r3fr3sh-value"))
    #expect(!redacted.contains("hunter2"))
    // Non-credential fields must survive or the log becomes useless.
    #expect(redacted.contains("alice"))
    #expect(redacted.contains("token"))
}

@Test func redactsBareJWTWithoutAKey() {
    #expect(!Redaction.redact("handshake rejected for \(sampleJWT)").contains(sampleJWT))
}

@Test func leavesCredentialFreeTextAlone() {
    let text = "connection lost after 3 attempts"
    #expect(Redaction.redact(text) == text)
}

@Test func describesAPIErrorsWithoutMessageBodies() {
    let error = APIServiceError.server(status: 401, code: "invalid_token", message: "token \(sampleJWT) expired")
    let described = Redaction.describe(error)
    #expect(described == "server(401/invalid_token)")
    #expect(!described.contains(sampleJWT))
}

@Test func describesTransportAndURLErrors() {
    #expect(Redaction.describe(RealtimeTransportError.notConnected) == "not_connected")
    #expect(Redaction.describe(RealtimeTransportError.acknowledgementTimedOut) == "ack_timeout")
    #expect(Redaction.describe(URLError(.notConnectedToInternet)).hasPrefix("url_error("))
}

@Test func describesUnknownErrorsThroughRedaction() {
    struct Leaky: Error, CustomStringConvertible {
        var description: String { "failed with token=\(sampleJWT)" }
    }
    #expect(!Redaction.describe(Leaky()).contains(sampleJWT))
}
