import AppKit
import AWSSSO
import AWSSSOOIDC
import Foundation

/// Default `AuthProviding` backed by `aws-sdk-swift` (B3, B4).
///
/// Flow (F-04, F-05):
/// 1. Reuse a non-expired cached `accessToken` from `~/.aws/sso/cache/`.
/// 2. Else, if a `refreshToken` is present, silently refresh via
///    `SSOOIDC.CreateToken(grant_type=refresh_token)` and update the cache.
/// 3. Else, run device authorization: `RegisterClient` → `StartDeviceAuthorization` →
///    open `verificationUriComplete` in the browser → poll `CreateToken(device_code)`.
///
/// All SSO/OIDC + `GetRoleCredentials` calls use the profile's **SSO region**
/// (`ssoRegion`), which is distinct from the resource region (B4).
final class AWSAuthProvider: AuthProviding {
    typealias OIDCClientFactory = @Sendable (_ ssoRegion: String) throws -> SSOOIDCClienting
    typealias SSOClientFactory = @Sendable (_ ssoRegion: String) throws -> SSOClienting

    private let cache: SSOCacheReading
    private let makeOIDCClient: OIDCClientFactory
    private let makeSSOClient: SSOClientFactory
    private let openURL: @Sendable (URL) -> Void
    /// Override the server-provided device-auth poll interval (tests use a tiny value).
    private let pollIntervalOverride: Duration?

    init(
        cache: SSOCacheReading = SSOCacheReader(),
        makeOIDCClient: @escaping OIDCClientFactory = { try SSOOIDCClient(region: $0) },
        makeSSOClient: @escaping SSOClientFactory = { try SSOClient(region: $0) },
        openURL: @escaping @Sendable (URL) -> Void = { url in
            Task { @MainActor in NSWorkspace.shared.open(url) }
        },
        pollIntervalOverride: Duration? = nil
    ) {
        self.cache = cache
        self.makeOIDCClient = makeOIDCClient
        self.makeSSOClient = makeSSOClient
        self.openURL = openURL
        self.pollIntervalOverride = pollIntervalOverride
    }

    // MARK: - AuthProviding

    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials {
        if let accessToken = try await validAccessToken(profile: profile) {
            return try await roleCredentials(profile: profile, accessToken: accessToken)
        }
        let accessToken = try await deviceAuthorize(profile: profile)
        return try await roleCredentials(profile: profile, accessToken: accessToken)
    }

    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        guard let accessToken = try await validAccessToken(profile: profile) else {
            throw AuthError.signInRequired
        }
        return try await roleCredentials(profile: profile, accessToken: accessToken)
    }

    // MARK: - Steps

    /// Returns a usable SSO `accessToken` from cache (reused or silently refreshed),
    /// or `nil` if interactive sign-in is required.
    private func validAccessToken(profile: ConnectionProfile) async throws -> String? {
        guard let token = try cache.token(startUrl: profile.ssoStartUrl, region: profile.ssoRegion) else {
            return nil
        }
        if !token.isExpired { return token.accessToken }
        guard token.canRefresh else { return nil }

        // Silent refresh is best-effort: a rejected/expired refresh token (e.g.
        // InvalidGrantException) must NOT fail the whole sign-in — fall back to the
        // interactive device-auth flow by returning nil (F-05).
        let output: CreateTokenOutput
        do {
            let client = try makeOIDCClient(profile.ssoRegion)
            output = try await client.createToken(CreateTokenInput(
                clientId: token.clientId,
                clientSecret: token.clientSecret,
                grantType: "refresh_token",
                refreshToken: token.refreshToken
            ))
        } catch {
            return nil
        }
        guard let newAccessToken = output.accessToken, !newAccessToken.isEmpty else { return nil }


        // Persist the refreshed token back to its existing cache file (best-effort, NF-01).
        let refreshed = SSOToken(
            startUrl: token.startUrl,
            region: token.region,
            accessToken: newAccessToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(output.expiresIn)),
            clientId: token.clientId,
            clientSecret: token.clientSecret,
            refreshToken: output.refreshToken ?? token.refreshToken,
            registrationExpiresAt: token.registrationExpiresAt
        )
        try? cache.update(refreshed)
        return newAccessToken
    }

    /// Full device-authorization grant (F-04). Opens the browser and polls until the user
    /// approves or the grant expires.
    private func deviceAuthorize(profile: ConnectionProfile) async throws -> String {
        let client = try makeOIDCClient(profile.ssoRegion)

        let registration = try await client.registerClient(RegisterClientInput(
            clientName: "SSM Connect",
            clientType: "public",
            scopes: ["sso:account:access"]
        ))
        guard let clientId = registration.clientId, let clientSecret = registration.clientSecret else {
            throw AuthError.deviceAuthorizationFailed
        }

        let authorization = try await client.startDeviceAuthorization(StartDeviceAuthorizationInput(
            clientId: clientId,
            clientSecret: clientSecret,
            startUrl: profile.ssoStartUrl
        ))
        guard let deviceCode = authorization.deviceCode else {
            throw AuthError.deviceAuthorizationFailed
        }
        if let urlString = authorization.verificationUriComplete, let url = URL(string: urlString) {
            openURL(url)
        }

        let interval = pollIntervalOverride ?? .seconds(max(authorization.interval, 1))
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))

        while Date() < deadline {
            do {
                let token = try await client.createToken(CreateTokenInput(
                    clientId: clientId,
                    clientSecret: clientSecret,
                    deviceCode: deviceCode,
                    grantType: "urn:ietf:params:oauth:grant-type:device_code"
                ))
                if let accessToken = token.accessToken, !accessToken.isEmpty {
                    return accessToken
                }
            } catch is AuthorizationPendingException {
                try await Task.sleep(for: interval)
            } catch is SlowDownException {
                try await Task.sleep(for: interval + .seconds(5))
            }
        }
        throw AuthError.deviceAuthTimedOut
    }

    /// Exchanges an SSO `accessToken` for temporary STS credentials (F-04).
    private func roleCredentials(profile: ConnectionProfile, accessToken: String) async throws -> AWSCredentials {
        let client = try makeSSOClient(profile.ssoRegion)
        let output = try await client.getRoleCredentials(GetRoleCredentialsInput(
            accessToken: accessToken,
            accountId: profile.accountId,
            roleName: profile.roleName
        ))
        guard let role = output.roleCredentials,
              let accessKeyId = role.accessKeyId,
              let secretAccessKey = role.secretAccessKey,
              let sessionToken = role.sessionToken else {
            throw AuthError.missingRoleCredentials
        }
        // SSO returns expiration as epoch milliseconds.
        return AWSCredentials(
            accessKeyId: accessKeyId,
            secretAccessKey: secretAccessKey,
            sessionToken: sessionToken,
            expiration: Date(timeIntervalSince1970: Double(role.expiration) / 1000)
        )
    }
}
