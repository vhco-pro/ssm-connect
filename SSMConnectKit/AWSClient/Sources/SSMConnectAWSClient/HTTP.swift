import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An HTTP request as the client sends it.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [(String, String)]
    public var body: Data

    public init(method: String, url: URL, headers: [(String, String)] = [], body: Data = Data()) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// An HTTP response as the client receives it.
public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public init(status: Int, headers: [(String, String)] = [], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }
}

/// Sends one HTTP request. Transport failures are thrown as `URLError`.
public protocol HTTPTransport: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// The production transport: one process-wide ephemeral `URLSession`, so signed and
/// token-bearing requests never land in a shared cache, and no session is released while the
/// process keeps working (on Linux that crashed in FoundationNetworking).
public struct URLSessionTransport: HTTPTransport {
    static let sharedSession = URLSession(configuration: .ephemeral)

    let session: URLSession

    public init() {
        session = Self.sharedSession
    }

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        for (name, value) in request.headers { urlRequest.addValue(value, forHTTPHeaderField: name) }
        if !request.body.isEmpty { urlRequest.httpBody = request.body }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let headers = http.allHeaderFields.compactMap { key, value -> (String, String)? in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}
