import Foundation

public enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case patch = "PATCH"
}

public enum APIServiceError: Error, Equatable, LocalizedError, Sendable {
    case invalidResponse
    case server(status: Int, code: String, message: String)
    case decoding

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The server returned an invalid HTTP response."
        case let .server(_, _, message):
            message
        case .decoding:
            "The server response did not match the expected PenguinChat contract."
        }
    }
}

public struct APIClient: Sendable {
    private let baseURL: URL
    private let transport: any HTTPTransport
    private let decoder: JSONDecoder

    public init(
        baseURL: URL,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.decoder = JSONDecoder()
    }

    public func request<Response: Decodable & Sendable>(
        _ path: String,
        method: HTTPMethod = .get,
        body: Data? = nil,
        accessToken: String? = nil
    ) async throws -> Response {
        let relativePath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let url = URL(string: relativePath, relativeTo: normalizedBaseURL) else {
            throw APIServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            let envelope = try? decoder.decode(ServerErrorEnvelope.self, from: data)
            throw APIServiceError.server(
                status: response.statusCode,
                code: envelope?.error ?? "request_failed",
                message: envelope?.message ?? HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
            )
        }

        do {
            return try decoder.decode(Response.self, from: data)
        } catch {
            throw APIServiceError.decoding
        }
    }

    private var normalizedBaseURL: URL {
        baseURL.absoluteString.hasSuffix("/")
            ? baseURL
            : URL(string: baseURL.absoluteString + "/")!
    }
}
