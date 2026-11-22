import Foundation
import SSMConnectAWSClient
import SSMConnectDomain
import SSMConnectWorkflow

/// SSO sign-in on SSM Connect's own AWS client: the `AuthProviding` for Windows and Linux, and
/// for macOS once T36 removes the SDK. It applies `AWSAuthProvider`'s rules with the same cache:
///
/// 1. Reuse a cached access token that is not within the renewal lead time of expiry.
/// 2. Else, when the cache has a refresh token and a live registration, refresh silently with
///    `CreateToken(grant_type=refresh_token)` and write the new token back; a rejected refresh
///    falls back to interactive sign-in.
/// 3. Else run the device authorization grant: `RegisterClient`, `StartDeviceAuthorization`,
///    open the verification URL, and poll `CreateToken(device_code)` at the server's interval,
///    slowing down when asked; the new token is cached for the next operation.
///
/// SSO calls use the profile's SSO region; role credentials come from `GetRoleCredentials`.
package final class ClientAuthProvider: AuthProviding, @unchecked Sendable {
    private let cache: SSOCacheReading
    private let clients: AWSClientFactory
    private let openURL: @Sendable (URL) -> Void
    private let pollIntervalOverride: Duration?
    private let now: @Sendable () -> Date
    private let renewalLeadTime: TimeInterval

    package init(cache: SSOCacheReading = SSOCacheReader(), clients: AWSClientFactory = AWSClientFactory(),
                 openURL: @escaping @Sendable (URL) -> Void, pollIntervalOverride: Duration? = nil,
                 now: @escaping @Sendable () -> Date = { Date() }, renewalLeadTime: TimeInterval = 300) {
        self.cache = cache
        self.clients = clients
        self.openURL = openURL
        self.pollIntervalOverride = pollIntervalOverride
        self.now = now
        self.renewalLeadTime = renewalLeadTime
    }

    // MARK: AuthProviding

    package func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials {
        if let accessToken = try await validAccessToken(profile: profile) {
            do { return try await roleCredentials(profile: profile, accessToken: accessToken) }
            catch { guard Self.isRejectedAuthorization(error) else { throw error } }
        }
        return try await signIn(profile: profile)
    }

    package func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        guard let accessToken = try await validAccessToken(profile: profile) else { throw AuthError.signInRequired }
        do { return try await roleCredentials(profile: profile, accessToken: accessToken) }
        catch {
            guard Self.isRejectedAuthorization(error) else { throw error }
            throw AuthError.signInRequired
        }
    }

    package func signIn(profile: ConnectionProfile) async throws -> AWSCredentials {
        try await roleCredentials(profile: profile, accessToken: try await deviceAuthorize(profile: profile))
    }

    package func authorizationMetadata(profile: ConnectionProfile) async throws -> AuthorizationMetadata? {
        guard let token = try cache.token(startUrl: profile.ssoStartUrl, region: profile.ssoRegion) else { return nil }
        return AuthorizationMetadata(accessTokenExpiry: token.expiresAt, canRefresh: token.canRefresh(at: now()))
    }

    // MARK: Steps

    private func validAccessToken(profile: ConnectionProfile) async throws -> String? {
        guard let token = try cache.token(startUrl: profile.ssoStartUrl, region: profile.ssoRegion) else { return nil }
        let now = now()
        if token.expiresAt.timeIntervalSince(now) > renewalLeadTime { return token.accessToken }
        guard token.canRefresh(at: now), let clientId = token.clientId, let clientSecret = token.clientSecret,
              let refreshToken = token.refreshToken else { return token.isExpired(at: now) ? nil : token.accessToken }
        // Silent refresh is best-effort: a rejected refresh token falls back to interactive sign-in.
        let refreshed: SSMConnectDomain.SSOToken
        do {
            let output = try await clients.make(nil, region: profile.ssoRegion)
                .createToken(clientId: clientId, clientSecret: clientSecret, grantType: "refresh_token", refreshToken: refreshToken)
            guard !output.accessToken.isEmpty else { throw AuthError.deviceAuthorizationFailed }
            refreshed = SSMConnectDomain.SSOToken(startUrl: token.startUrl, region: token.region, accessToken: output.accessToken,
                                 expiresAt: now.addingTimeInterval(TimeInterval(output.expiresIn)), clientId: clientId,
                                 clientSecret: clientSecret, refreshToken: output.refreshToken ?? refreshToken,
                                 registrationExpiresAt: token.registrationExpiresAt)
        } catch {
            if error is CancellationError { throw error }
            guard Self.isRejectedAuthorization(error) || (error as? AWSServiceError)?.typeName == "InvalidRequestException" else {
                throw error
            }
            return nil
        }
        try? cache.update(refreshed)
        return refreshed.accessToken
    }

    private func deviceAuthorize(profile: ConnectionProfile) async throws -> String {
        let client = clients.make(nil, region: profile.ssoRegion)
        let registration = try await client.registerClient(clientName: "SSM Connect", clientType: "public",
                                                           scopes: ["sso:account:access"])
        let authorization = try await client.startDeviceAuthorization(clientId: registration.clientId,
                                                                      clientSecret: registration.clientSecret,
                                                                      startUrl: profile.ssoStartUrl)
        if let text = authorization.verificationUriComplete, let url = URL(string: text) { openURL(url) }
        let interval = pollIntervalOverride ?? .seconds(max(authorization.interval, 1))
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
        while Date() < deadline {
            try Task.checkCancellation()
            do {
                let token = try await client.createToken(clientId: registration.clientId, clientSecret: registration.clientSecret,
                                                         grantType: "urn:ietf:params:oauth:grant-type:device_code",
                                                         deviceCode: authorization.deviceCode)
                if !token.accessToken.isEmpty {
                    try? cache.update(SSMConnectDomain.SSOToken(
                        startUrl: profile.ssoStartUrl, region: profile.ssoRegion, accessToken: token.accessToken,
                        expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn)), clientId: registration.clientId,
                        clientSecret: registration.clientSecret, refreshToken: token.refreshToken,
                        registrationExpiresAt: registration.clientSecretExpiresAt > 0
                            ? Date(timeIntervalSince1970: TimeInterval(registration.clientSecretExpiresAt)) : nil))
                    return token.accessToken
                }
                try await Task.sleep(for: interval)
            } catch let error as AWSServiceError where error.typeName == "AuthorizationPendingException" {
                try await Task.sleep(for: interval)
            } catch let error as AWSServiceError where error.typeName == "SlowDownException" {
                try await Task.sleep(for: interval + .seconds(5))
            } catch let error as AWSServiceError where error.typeName == "InvalidGrantException" {
                if let completed = try await validAccessToken(profile: profile) { return completed }
                throw AuthError.signInRequired
            }
        }
        throw AuthError.deviceAuthTimedOut
    }

    private func roleCredentials(profile: ConnectionProfile, accessToken: String) async throws -> AWSCredentials {
        let role: RoleCredentials
        do {
            role = try await clients.make(nil, region: profile.ssoRegion)
                .getRoleCredentials(accessToken: accessToken, accountId: profile.accountId, roleName: profile.roleName)
        } catch AWSClientError.malformedResponse(operation: "GetRoleCredentials") {
            // A reply without role credentials, as the SDK provider reported it.
            throw AuthError.missingRoleCredentials
        } catch {
            // Signed in but not assigned this permission set: re-authenticating cannot fix it.
            guard Self.isRoleAccessDenied(error) else { throw error }
            throw AuthError.roleAccessDenied(accountId: profile.accountId, roleName: profile.roleName,
                                             detail: (error as? AWSServiceError)?.typeName)
        }
        // SSO returns expiration as epoch milliseconds.
        return AWSCredentials(accessKeyId: role.accessKeyId, secretAccessKey: role.secretAccessKey,
                              sessionToken: role.sessionToken,
                              expiration: Date(timeIntervalSince1970: Double(role.expirationMilliseconds) / 1000))
    }

    // MARK: Error rules (the same names AWSAuthProvider matches on the SDK's errors)

    package static func isRoleAccessDenied(_ error: Error) -> Bool {
        guard let error = error as? AWSServiceError else { return false }
        return error.httpStatus == 403 || error.typeName == "ForbiddenException"
    }

    package static func isRejectedAuthorization(_ error: Error) -> Bool {
        if error as? AuthError == .signInRequired { return true }
        guard let name = (error as? AWSServiceError)?.typeName else { return false }
        return ["UnauthorizedException", "ExpiredToken", "ExpiredTokenException", "UnauthorizedAccess",
                "UnauthorizedAccessException", "InvalidGrantException", "InvalidClientException",
                "UnauthorizedClientException"].contains(name)
    }

    package static func isPermissionDenied(_ error: Error) -> Bool {
        guard let name = (error as? AWSServiceError)?.typeName else { return false }
        return ["AccessDenied", "AccessDeniedException", "UnauthorizedOperation", "ForbiddenException"].contains(name)
    }
}
