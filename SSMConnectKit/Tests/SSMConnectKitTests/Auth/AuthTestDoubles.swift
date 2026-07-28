@_spi(UnknownAWSHTTPServiceError) import AWSClientRuntime
import AWSSSO
import AWSSSOOIDC
import Foundation
import SmithyHTTPAPI
@testable import SSMConnectKit

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

/// Builds the error the real SDK hands back when a service returns an error shape that is
/// absent from the operation's Smithy model (#20).
///
/// `SSO.GetRoleCredentials` models only `InvalidRequestException`, `ResourceNotFoundException`,
/// `TooManyRequestsException`, and `UnauthorizedException`. A real "you are not assigned this
/// permission set" reply is a 403 `ForbiddenException`, which is *not* in that list, so the SDK
/// wraps it as `UnknownAWSHTTPServiceError`. Using the genuine type keeps these tests honest:
/// if a future SDK models `ForbiddenException` properly, they still pass via the `ServiceError`
/// conformance both types share.
func unmodeledAWSServiceError(
    typeName: String?,
    message: String?,
    statusCode: HTTPStatusCode
) -> any Error {
    UnknownAWSHTTPServiceError(
        httpResponse: HTTPResponse(statusCode: statusCode),
        message: message,
        requestID: "req-1234",
        typeName: typeName
    )
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
