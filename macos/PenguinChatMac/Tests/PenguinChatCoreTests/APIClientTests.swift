import Foundation
import Testing
@testable import PenguinChatCore

private struct StubTransport: HTTPTransport {
    let statusCode: Int
    let data: Data
    let inspect: @Sendable (URLRequest) -> Void

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        inspect(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

@Test func clientBuildsBearerRequestAndDecodesSnakeCaseUser() async throws {
    let payload = Data(#"{"user":{"id":"u1","username":"alice","display_name":"Alice","avatar_url":null,"signature":null,"created_at":"2026-08-15T00:00:00Z"}}"#.utf8)
    let transport = StubTransport(statusCode: 200, data: payload) { request in
        #expect(request.url?.absoluteString == "http://127.0.0.1:3000/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer access-token")
    }
    let client = APIClient(baseURL: AppEnvironment.local.apiBaseURL, transport: transport)

    let response: UserEnvelope = try await client.request("/me", accessToken: "access-token")

    #expect(response.user.displayName == "Alice")
}

@Test func clientDecodesServerErrorEnvelope() async {
    let payload = Data(#"{"error":"invalid_credentials","message":"Invalid username or password"}"#.utf8)
    let client = APIClient(
        baseURL: AppEnvironment.local.apiBaseURL,
        transport: StubTransport(statusCode: 401, data: payload, inspect: { _ in })
    )

    await #expect(throws: APIServiceError.server(
        status: 401,
        code: "invalid_credentials",
        message: "Invalid username or password"
    )) {
        let _: AuthResult = try await client.request("/auth/login", method: .post, body: Data())
    }
}
