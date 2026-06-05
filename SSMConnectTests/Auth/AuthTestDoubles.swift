import AWSSSO
import AWSSSOOIDC
import Foundation
@testable import SSMConnect

// Test doubles for the SSO/OIDC client seams + cache (B7, ADR-P2).

final class MockSSOCache: SSOCacheReading, @unchecked Sendable {
    var stored: SSOToken?
    private(set) var updatedToken: SSOToken?

    init(stored: SSOToken? = nil) { self.stored = stored }

    func token(startUrl: String, region: String) throws -> SSOToken? {
        guard let stored, stored.startUrl == startUrl, stored.region == region else { return nil }
        return stored
    }

    func update(_ token: SSOToken) throws {
        updatedToken = token
        stored = token
    }
}

final class MockOIDCClient: SSOOIDCClienting, @unchecked Sendable {
    var registerOutput = RegisterClientOutput(clientId: "client-id", clientSecret: "client-secret")
    var deviceAuthOutput = StartDeviceAuthorizationOutput(
        deviceCode: "device-code",
        expiresIn: 60,
        interval: 1,
        userCode: "USER-CODE",
        verificationUri: "https://example.com/device",
        verificationUriComplete: "https://example.com/device?user_code=USER-CODE"
    )
    /// Results returned by successive `createToken` calls. The last entry repeats if the
    /// provider calls more times than there are entries.
    var createTokenResults: [Result<CreateTokenOutput, any Error>] = [
        .success(CreateTokenOutput(accessToken: "access-token", expiresIn: 3600))
    ]

    private(set) var registerCount = 0
    private(set) var deviceAuthCount = 0
    private(set) var createTokenCount = 0
    private(set) var lastCreateTokenInput: CreateTokenInput?

    func registerClient(_ input: RegisterClientInput) async throws -> RegisterClientOutput {
        registerCount += 1
        return registerOutput
    }

    func startDeviceAuthorization(_ input: StartDeviceAuthorizationInput) async throws -> StartDeviceAuthorizationOutput {
        deviceAuthCount += 1
        return deviceAuthOutput
    }

    func createToken(_ input: CreateTokenInput) async throws -> CreateTokenOutput {
        lastCreateTokenInput = input
        let index = min(createTokenCount, createTokenResults.count - 1)
        createTokenCount += 1
        switch createTokenResults[index] {
        case let .success(output): return output
        case let .failure(error): throw error
        }
    }
}

final class MockSSOClient: SSOClienting, @unchecked Sendable {
    var output = GetRoleCredentialsOutput(
        roleCredentials: SSOClientTypes.RoleCredentials(
            accessKeyId: "AKIAEXAMPLE",
            expiration: 0,
            secretAccessKey: "secret",
            sessionToken: "session"
        )
    )
    var error: (any Error)?

    private(set) var callCount = 0
    private(set) var lastInput: GetRoleCredentialsInput?

    func getRoleCredentials(_ input: GetRoleCredentialsInput) async throws -> GetRoleCredentialsOutput {
        callCount += 1
        lastInput = input
        if let error { throw error }
        return output
    }
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
