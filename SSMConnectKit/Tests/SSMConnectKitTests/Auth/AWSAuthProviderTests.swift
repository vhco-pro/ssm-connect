import AWSSSO
import AWSSSOOIDC
import Foundation
import Testing
@testable import SSMConnectKit

// Task B7 — AWSAuthProvider orchestration tests with mocked SDK clients (F-04, F-05).
// Covers: valid-cache path, silent-refresh path, device-auth (incl. pending polling),
// silent-only refreshIfNeeded, and missing-credentials failure.
@Suite("AWSAuthProvider")
struct AWSAuthProviderTests {

    private let profile = ConnectionProfile.example

    private func validToken() -> SSOToken {
        SSOToken(
            startUrl: profile.ssoStartUrl,
            region: profile.ssoRegion,
            accessToken: "cached-access",
            expiresAt: Date().addingTimeInterval(3600),
            clientId: nil, clientSecret: nil, refreshToken: nil, registrationExpiresAt: nil
        )
    }

    private func refreshableExpiredToken() -> SSOToken {
        SSOToken(
            startUrl: profile.ssoStartUrl,
            region: profile.ssoRegion,
            accessToken: "stale-access",
            expiresAt: Date().addingTimeInterval(-60),
            clientId: "client-id",
            clientSecret: "client-secret",
            refreshToken: "refresh-token",
            registrationExpiresAt: Date().addingTimeInterval(86_400)
        )
    }

    private func makeProvider(
        cache: MockSSOCache,
        oidc: MockOIDCClient,
        sso: MockSSOClient,
        recorder: URLRecorder
    ) -> AWSAuthProvider {
        AWSAuthProvider(
            cache: cache,
            makeOIDCClient: { _ in oidc },
            makeSSOClient: { _ in sso },
            openURL: { recorder.record($0) },
            pollIntervalOverride: .milliseconds(1)
        )
    }

    @Test("Valid cached token yields credentials without refresh or browser")
    func validCachedToken() async throws {
        let cache = MockSSOCache(stored: validToken())
        let oidc = MockOIDCClient()
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        let credentials = try await provider.authenticate(profile: profile)

        #expect(credentials.accessKeyId == "AKIAEXAMPLE")
        #expect(oidc.createTokenCount == 0)
        #expect(oidc.registerCount == 0)
        #expect(sso.callCount == 1)
        #expect(recorder.urls.isEmpty)
        #expect(sso.lastInput?.accessToken == "cached-access")
    }

    @Test("Expired token triggers a silent refresh and cache write-back, no browser")
    func silentRefresh() async throws {
        let cache = MockSSOCache(stored: refreshableExpiredToken())
        let oidc = MockOIDCClient()
        oidc.createTokenResults = [.success(CreateTokenOutput(accessToken: "refreshed-access", expiresIn: 3600))]
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        _ = try await provider.authenticate(profile: profile)

        #expect(oidc.createTokenCount == 1)
        #expect(oidc.lastCreateTokenInput?.grantType == "refresh_token")
        #expect(oidc.registerCount == 0)
        #expect(recorder.urls.isEmpty)
        #expect(cache.updatedToken?.accessToken == "refreshed-access")
        #expect(sso.lastInput?.accessToken == "refreshed-access")
    }

    @Test("Failed silent refresh falls back to device authorization, not an error")
    func refreshFailureFallsBackToDeviceAuth() async throws {
        let cache = MockSSOCache(stored: refreshableExpiredToken())
        let oidc = MockOIDCClient()
        // 1st createToken = refresh attempt (rejected); 2nd = device_code poll (success).
        oidc.createTokenResults = [
            .failure(InvalidGrantException()),
            .success(CreateTokenOutput(accessToken: "access-token", expiresIn: 3600))
        ]
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        let credentials = try await provider.authenticate(profile: profile)

        #expect(oidc.registerCount == 1)        // fell back to device auth
        #expect(oidc.deviceAuthCount == 1)
        #expect(recorder.urls.count == 1)       // browser opened
        #expect(credentials.sessionToken == "session")
    }

    @Test("No cached token runs device authorization and opens the browser")
    func deviceAuthorization() async throws {
        let cache = MockSSOCache(stored: nil)
        let oidc = MockOIDCClient()
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        _ = try await provider.authenticate(profile: profile)

        #expect(oidc.registerCount == 1)
        #expect(oidc.deviceAuthCount == 1)
        #expect(recorder.urls.count == 1)
        #expect(oidc.lastCreateTokenInput?.grantType == "urn:ietf:params:oauth:grant-type:device_code")
        #expect(sso.callCount == 1)
    }

    @Test("Device authorization polls through AuthorizationPending before succeeding")
    func deviceAuthorizationPolls() async throws {
        let cache = MockSSOCache(stored: nil)
        let oidc = MockOIDCClient()
        oidc.createTokenResults = [
            .failure(AuthorizationPendingException()),
            .failure(AuthorizationPendingException()),
            .success(CreateTokenOutput(accessToken: "access-token", expiresIn: 3600))
        ]
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        let credentials = try await provider.authenticate(profile: profile)

        #expect(oidc.createTokenCount == 3)
        #expect(credentials.sessionToken == "session")
    }

    @Test("Device authorization persists the new token to the cache for later reuse (F-05)")
    func deviceAuthPersistsToken() async throws {
        let cache = MockSSOCache(stored: nil)
        let oidc = MockOIDCClient()
        oidc.registerOutput = RegisterClientOutput(
            clientId: "new-client-id", clientSecret: "new-client-secret", clientSecretExpiresAt: 4_102_444_800
        )
        oidc.createTokenResults = [
            .success(CreateTokenOutput(accessToken: "fresh-access", expiresIn: 3600, refreshToken: "fresh-refresh"))
        ]
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        _ = try await provider.authenticate(profile: profile)

        // The device-auth result was written back so the next connect can reuse / refresh it.
        #expect(cache.updatedToken?.accessToken == "fresh-access")
        #expect(cache.updatedToken?.refreshToken == "fresh-refresh")
        #expect(cache.updatedToken?.clientId == "new-client-id")
        #expect(cache.updatedToken?.clientSecret == "new-client-secret")
        #expect(cache.updatedToken?.startUrl == profile.ssoStartUrl)
        #expect(cache.updatedToken?.canRefresh == true)
    }

    @Test("refreshIfNeeded throws signInRequired with no cached token and never opens a browser")
    func refreshIfNeededRequiresSignIn() async throws {
        let cache = MockSSOCache(stored: nil)
        let oidc = MockOIDCClient()
        let sso = MockSSOClient()
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        await #expect(throws: AuthError.signInRequired) {
            _ = try await provider.refreshIfNeeded(profile: profile)
        }
        #expect(recorder.urls.isEmpty)
        #expect(oidc.registerCount == 0)
    }

    @Test("Missing role credentials surface as AuthError.missingRoleCredentials")
    func missingRoleCredentials() async throws {
        let cache = MockSSOCache(stored: validToken())
        let oidc = MockOIDCClient()
        let sso = MockSSOClient()
        sso.output = GetRoleCredentialsOutput(roleCredentials: nil)
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        await #expect(throws: AuthError.missingRoleCredentials) {
            _ = try await provider.authenticate(profile: profile)
        }
    }

    @Test("Role-credential expiration is converted from epoch milliseconds")
    func expirationFromMilliseconds() async throws {
        let cache = MockSSOCache(stored: validToken())
        let oidc = MockOIDCClient()
        let sso = MockSSOClient()
        sso.output = GetRoleCredentialsOutput(
            roleCredentials: SSOClientTypes.RoleCredentials(
                accessKeyId: "AK", expiration: 1_700_000_000_000, secretAccessKey: "SK", sessionToken: "ST"
            )
        )
        let recorder = URLRecorder()
        let provider = makeProvider(cache: cache, oidc: oidc, sso: sso, recorder: recorder)

        let credentials = try await provider.authenticate(profile: profile)
        #expect(credentials.expiration == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
