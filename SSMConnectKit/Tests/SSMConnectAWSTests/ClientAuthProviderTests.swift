import Foundation
import Testing
import SSMConnectAWSClient
@testable import SSMConnectAWS
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// SSO sign-in on SSM Connect's client (T47, AC-15, AC-28): cache reuse, silent refresh, the
/// device authorization grant, role credentials and the AWS CLI cache file.
@Suite("Client SSO provider")
struct ClientAuthProviderTests {
    static let startURL = "https://d-0123456789.awsapps.com/start"
    /// SHA-1 of the start URL, as the AWS CLI names the cache file.
    static let cacheFile = "aa477cedd4b2708a54ce60d7ae5a3b7f986013da.json"
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static var profile: ConnectionProfile {
        ConnectionProfile(name: "Workstation", ssoStartUrl: startURL, ssoRegion: "eu-west-1", accountId: "111122223333",
                          roleName: "Admin", resourceRegion: "eu-central-1", instanceTagKey: "Name", instanceTagValue: "ws",
                          localPort: 8443, remotePort: 8443)
    }

    /// Answers by endpoint and records each request's path.
    final class SSOService: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var tokenReplies: [HTTPResponse]
        private(set) var paths: [String] = []
        /// The bearer token of each GetRoleCredentials request, in order.
        private(set) var roleTokens: [String] = []
        /// The grant_type of each CreateToken request, in order.
        private(set) var grants: [String] = []
        var role = HTTPResponse(status: 200, body: Data(#"{"roleCredentials":{"accessKeyId":"AKID","secretAccessKey":"secret","sessionToken":"session","expiration":1800003600000}}"#.utf8))
        /// Replies for GetRoleCredentials by bearer token; others get `role`.
        var roleByToken: [String: HTTPResponse] = [:]
        /// Thrown by the transport for CreateToken instead of a reply (a network failure).
        var tokenFailure: Error?
        /// Runs when CreateToken is called, before it answers.
        var onToken: () -> Void = {}

        init(token: [HTTPResponse] = []) { tokenReplies = token }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let path = request.url.path
            if path == "/token" {
                onToken()
                if let failure = lock.withLock({ tokenFailure }) {
                    lock.withLock { paths.append(path) }
                    throw failure
                }
            }
            return lock.withLock {
                paths.append(path)
                switch path {
                case "/client/register":
                    return HTTPResponse(status: 200, body: Data(#"{"clientId":"client","clientSecret":"client-secret","clientSecretExpiresAt":1807776000}"#.utf8))
                case "/device_authorization":
                    return HTTPResponse(status: 200, body: Data(#"{"deviceCode":"device","userCode":"ABCD-EFGH","verificationUriComplete":"https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH","expiresIn":600,"interval":1}"#.utf8))
                case "/token":
                    let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any]
                    grants.append(body?["grantType"] as? String ?? body?["grant_type"] as? String ?? "")
                    return tokenReplies.count > 1 ? tokenReplies.removeFirst() : tokenReplies[0]
                case "/federation/credentials":
                    let bearer = request.headers.first { $0.0.lowercased() == "x-amz-sso_bearer_token" }?.1 ?? ""
                    roleTokens.append(bearer)
                    return roleByToken[bearer] ?? role
                default:
                    return HTTPResponse(status: 404)
                }
            }
        }
    }

    static func error(_ type: String, status: Int = 400) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("x-amzn-ErrorType", type)], body: Data(#"{"error":"x","error_description":"scripted"}"#.utf8))
    }
    static func token(_ access: String, refresh: String? = "refresh-2") -> HTTPResponse {
        let refreshField = refresh.map { #","refreshToken":"\#($0)""# } ?? ""
        return HTTPResponse(status: 200, body: Data(#"{"accessToken":"\#(access)","tokenType":"Bearer","expiresIn":3600\#(refreshField)}"#.utf8))
    }

    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sso-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    final class Opened: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []
        func append(_ url: URL) { lock.withLock { urls.append(url) } }
        var all: [URL] { lock.withLock { urls } }
    }

    static func provider(_ service: SSOService, cache: URL, opened: Opened = Opened()) -> ClientAuthProvider {
        ClientAuthProvider(cache: SSOCacheReader(directory: cache), clients: AWSClientFactory(transport: service),
                           openURL: { opened.append($0) }, pollIntervalOverride: .milliseconds(1), now: { now })
    }

    static func seed(_ cache: URL, accessToken: String, expiresIn: TimeInterval, refresh: Bool) throws {
        try SSOCacheReader(directory: cache).update(SSOToken(
            startUrl: startURL, region: "eu-west-1", accessToken: accessToken, expiresAt: now.addingTimeInterval(expiresIn),
            clientId: refresh ? "client" : nil, clientSecret: refresh ? "client-secret" : nil,
            refreshToken: refresh ? "refresh-1" : nil,
            registrationExpiresAt: refresh ? now.addingTimeInterval(86_400) : nil))
    }

    @Test("A cached token well before expiry is reused without any SSO OIDC call")
    func reuse() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService()
        let credentials = try await Self.provider(service, cache: cache).authenticate(profile: Self.profile)
        #expect(credentials == AWSCredentials(accessKeyId: "AKID", secretAccessKey: "secret", sessionToken: "session",
                                              expiration: Date(timeIntervalSince1970: 1_800_003_600)))
        #expect(service.paths == ["/federation/credentials"])
    }

    @Test("A token near expiry is refreshed silently and written back to the same cache file")
    func refresh() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 60, refresh: true)
        let service = SSOService(token: [Self.token("renewed")])
        _ = try await Self.provider(service, cache: cache).refreshIfNeeded(profile: Self.profile)
        #expect(service.paths == ["/token", "/federation/credentials"])
        let cached = try #require(try SSOCacheReader(directory: cache).token(startUrl: Self.startURL, region: "eu-west-1"))
        #expect(cached.accessToken == "renewed" && cached.refreshToken == "refresh-2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [Self.cacheFile])
    }

    @Test("A rejected refresh falls back to the device authorization grant")
    func rejectedRefresh() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 60, refresh: true)
        let service = SSOService(token: [Self.error("InvalidGrantException"), Self.token("fresh")])
        let opened = Opened()
        _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        #expect(service.paths == ["/token", "/client/register", "/device_authorization", "/token", "/federation/credentials"])
        #expect(opened.all.count == 1)
    }

    @Test("Device authorization opens the URL, waits while pending or slowed, and caches the token as the AWS CLI does")
    func deviceAuthorization() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = SSOService(token: [Self.error("AuthorizationPendingException"), Self.error("SlowDownException"), Self.token("fresh")])
        let opened = Opened()
        let started = ContinuousClock.now
        _ = try await Self.provider(service, cache: cache, opened: opened).signIn(profile: Self.profile)
        #expect(ContinuousClock.now - started >= .seconds(5)) // slow_down adds five seconds
        #expect(opened.all == [URL(string: "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD-EFGH")!])
        #expect(try FileManager.default.contentsOfDirectory(atPath: cache.path) == [Self.cacheFile])
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: cache.appendingPathComponent(Self.cacheFile))) as? [String: Any]
        #expect(Set(object?.keys.map { $0 } ?? []) == ["startUrl", "region", "accessToken", "expiresAt", "clientId", "clientSecret",
                                                        "refreshToken", "registrationExpiresAt"])
        #expect(object?["accessToken"] as? String == "fresh" && object?["region"] as? String == "eu-west-1")
    }

    @Test("Without a usable cached token, refresh asks for sign-in")
    func refreshNeedsSignIn() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = SSOService()
        let opened = Opened()
        await #expect(throws: AuthError.signInRequired) {
            _ = try await Self.provider(service, cache: cache, opened: opened).refreshIfNeeded(profile: Self.profile)
        }
        #expect(opened.all.isEmpty && service.paths.isEmpty)
    }

    @Test("A role the user is not assigned is reported by account and role, not as a sign-in problem")
    func roleAccessDenied() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService()
        service.role = Self.error("ForbiddenException", status: 403)
        let thrown = await #expect(throws: AuthError.roleAccessDenied(accountId: "111122223333", roleName: "Admin", detail: "ForbiddenException")) {
            _ = try await Self.provider(service, cache: cache).authenticate(profile: Self.profile)
        }
        // The message is actionable and does not read as a transient sign-in problem.
        let description = try #require(thrown?.errorDescription)
        #expect(description.contains("111122223333") && description.contains("Admin") && !description.contains("error 1"))
    }

    // MARK: Ported from the SDK provider's tests (T36)

    @Test("A refreshable token one second inside the renewal lead time renews before its known expiry, without a browser")
    func renewsInsideLeadTime() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 299, refresh: true)
        let service = SSOService(token: [Self.token("renewed")])
        let opened = Opened()
        _ = try await Self.provider(service, cache: cache, opened: opened).refreshIfNeeded(profile: Self.profile)
        #expect(service.grants == ["refresh_token"] && opened.all.isEmpty)
    }

    @Test("A revoked cached token falls through to a fresh interactive sign-in")
    func revokedCachedToken() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService(token: [Self.token("fresh")])
        service.roleByToken["cached"] = Self.error("UnauthorizedException", status: 401)
        let opened = Opened()
        _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        #expect(service.roleTokens == ["cached", "fresh"] && opened.all.count == 1)
    }

    @Test("An offline silent refresh fails without starting browser sign-in")
    func offlineRefresh() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 60, refresh: true)
        let service = SSOService()
        service.tokenFailure = URLError(.notConnectedToInternet)
        let opened = Opened()
        await #expect(throws: (any Error).self) {
            _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        }
        #expect(opened.all.isEmpty && !service.paths.contains("/device_authorization"))
    }

    @Test("A cancelled silent refresh stays cancelled and never opens a browser")
    func cancelledRefresh() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 60, refresh: true)
        let service = SSOService()
        service.tokenFailure = CancellationError()
        let opened = Opened()
        await #expect(throws: CancellationError.self) {
            _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        }
        #expect(opened.all.isEmpty)
    }

    @Test("A refresh rejected as an invalid request needs a fresh sign-in, not an opaque connection error",
          arguments: [false, true])
    func invalidRefreshRequest(interactive: Bool) async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "old", expiresIn: 60, refresh: true)
        let service = SSOService(token: [Self.error("InvalidRequestException"), Self.token("fresh")])
        let opened = Opened()
        let provider = Self.provider(service, cache: cache, opened: opened)
        if interactive {
            _ = try await provider.authenticate(profile: Self.profile)
            #expect(service.paths.contains("/device_authorization") && opened.all.count == 1 && service.roleTokens == ["fresh"])
        } else {
            await #expect(throws: AuthError.signInRequired) { _ = try await provider.refreshIfNeeded(profile: Self.profile) }
            #expect(!service.paths.contains("/client/register") && opened.all.isEmpty && service.roleTokens.isEmpty)
        }
    }

    @Test("An invalid role request is not mistaken for a rejected refresh grant", arguments: [false, true])
    func invalidRoleRequest(interactive: Bool) async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService()
        service.role = Self.error("InvalidRequestException")
        let opened = Opened()
        let provider = Self.provider(service, cache: cache, opened: opened)
        let thrown = await #expect(throws: AWSServiceError.self) {
            if interactive { _ = try await provider.authenticate(profile: Self.profile) }
            else { _ = try await provider.refreshIfNeeded(profile: Self.profile) }
        }
        #expect(thrown?.typeName == "InvalidRequestException")
        #expect(service.roleTokens.count == 1 && opened.all.isEmpty && !service.paths.contains("/client/register"))
    }

    @Test("A rejected device grant adopts a sign-in another process completed meanwhile")
    func adoptsSharedSignIn() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = SSOService(token: [Self.error("InvalidGrantException")])
        service.onToken = { try? Self.seed(cache, accessToken: "shared", expiresIn: 3600, refresh: false) }
        let opened = Opened()
        _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        #expect(opened.all.count == 1 && service.roleTokens == ["shared"])
    }

    @Test("A rejected device grant with no sign-in to adopt asks for sign-in")
    func rejectedDeviceGrant() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        let service = SSOService(token: [Self.error("InvalidGrantException")])
        let opened = Opened()
        await #expect(throws: AuthError.signInRequired) {
            _ = try await Self.provider(service, cache: cache, opened: opened).authenticate(profile: Self.profile)
        }
        #expect(opened.all.count == 1 && service.roleTokens.isEmpty)
    }

    @Test("A role-credentials reply without credentials is reported as missing role credentials")
    func missingRoleCredentials() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService()
        service.role = HTTPResponse(status: 200, body: Data("{}".utf8))
        await #expect(throws: AuthError.missingRoleCredentials) {
            _ = try await Self.provider(service, cache: cache).authenticate(profile: Self.profile)
        }
    }

    @Test("A 401 from GetRoleCredentials is left for the re-authentication path, not called a missing role")
    func unauthorizedRoleRequest() async throws {
        let cache = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Self.seed(cache, accessToken: "cached", expiresIn: 3600, refresh: false)
        let service = SSOService(token: [Self.token("fresh")])
        service.role = Self.error("UnauthorizedException", status: 401)
        let thrown = await #expect(throws: AWSServiceError.self) {
            _ = try await Self.provider(service, cache: cache).authenticate(profile: Self.profile)
        }
        #expect(thrown?.typeName == "UnauthorizedException")
        #expect(!ClientAuthProvider.isRoleAccessDenied(try #require(thrown)))
    }

    @Test("Rejected-authorization and permission errors are recognised by type name")
    func errorRules() {
        #expect(ClientAuthProvider.isRejectedAuthorization(AWSServiceError(typeName: "UnauthorizedException", message: nil, httpStatus: 401)))
        #expect(ClientAuthProvider.isRejectedAuthorization(AuthError.signInRequired))
        #expect(!ClientAuthProvider.isRejectedAuthorization(AWSServiceError(typeName: "Throttling", message: nil, httpStatus: 400)))
        #expect(ClientAuthProvider.isPermissionDenied(AWSServiceError(typeName: "AccessDeniedException", message: nil, httpStatus: 400)))
    }
}
