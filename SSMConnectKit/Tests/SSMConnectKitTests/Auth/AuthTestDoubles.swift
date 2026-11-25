import Foundation
import SSMConnectAWSClient
@testable import SSMConnectDomain
@testable import SSMConnectKit

// Test doubles for SSO sign-in on SSM Connect's AWS client: the cache, a scripted SSO endpoint,
// service errors as the client reports them, and the URLs a provider opens.

final class MockSSOCache: SSOCacheReading, @unchecked Sendable {
    var stored: SSMConnectDomain.SSOToken?
    private(set) var updatedToken: SSMConnectDomain.SSOToken?

    init(stored: SSMConnectDomain.SSOToken? = nil) { self.stored = stored }

    func token(startUrl: String, region: String) throws -> SSMConnectDomain.SSOToken? {
        guard let stored, stored.startUrl == startUrl, stored.region == region else { return nil }
        return stored
    }

    func update(_ token: SSMConnectDomain.SSOToken) throws {
        updatedToken = token
        stored = token
    }
}

/// SSO OIDC and the SSO portal on one scripted transport: client registration and device
/// authorization succeed, CreateToken answers from a queue, and GetRoleCredentials returns
/// credentials valid for an hour.
final class ScriptedSSO: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var tokenReplies: [HTTPResponse]
    private(set) var registerCount = 0

    init(tokens: [HTTPResponse]) { tokenReplies = tokens }

    static func error(_ type: String, status: Int = 400) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("x-amzn-ErrorType", type)], body: Data(#"{"error":"x","error_description":"scripted"}"#.utf8))
    }

    static func token(_ access: String) -> HTTPResponse {
        HTTPResponse(status: 200, body: Data(#"{"accessToken":"\#(access)","tokenType":"Bearer","expiresIn":3600}"#.utf8))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            switch request.url.path {
            case "/client/register":
                registerCount += 1
                return HTTPResponse(status: 200, body: Data(#"{"clientId":"client","clientSecret":"secret","clientSecretExpiresAt":4102444800}"#.utf8))
            case "/device_authorization":
                return HTTPResponse(status: 200, body: Data(#"{"deviceCode":"device","userCode":"ABCD","verificationUriComplete":"https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD","expiresIn":600,"interval":1}"#.utf8))
            case "/token":
                return tokenReplies.count > 1 ? tokenReplies.removeFirst() : tokenReplies[0]
            case "/federation/credentials":
                let expiration = Int64((Date().timeIntervalSince1970 + 3600) * 1000)
                return HTTPResponse(status: 200, body: Data(#"{"roleCredentials":{"accessKeyId":"fixture","secretAccessKey":"fixture","sessionToken":"fixture","expiration":\#(expiration)}}"#.utf8))
            default:
                return HTTPResponse(status: 404)
            }
        }
    }
}

/// HTTP statuses the tests give their service errors.
enum HTTPStatusCode: Int {
    case badRequest = 400, unauthorized = 401, forbidden = 403
}

/// An AWS service error as SSM Connect's client reports one: the wire type name, message and
/// status, whatever the operation.
func unmodeledAWSServiceError(typeName: String?, message: String?, statusCode: HTTPStatusCode) -> any Error {
    AWSServiceError(typeName: typeName ?? "", message: message, httpStatus: statusCode.rawValue)
}

/// Thread-safe recorder for URLs passed to the provider's `openURL` closure.
final class URLRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func record(_ url: URL) {
        lock.lock(); defer { lock.unlock() }
        storage.append(url)
    }

    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
