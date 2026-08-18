import AWSSSO
import AWSSSOOIDC
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Thin seams over the `aws-sdk-swift` SSO/OIDC clients so `AWSAuthProvider` can be
/// unit-tested with mocked SDK clients (B7, ADR-P2). The real SDK clients conform via
/// the extensions below.

public protocol SSOOIDCClienting: Sendable {
    func registerClient(_ input: RegisterClientInput) async throws -> RegisterClientOutput
    func startDeviceAuthorization(_ input: StartDeviceAuthorizationInput) async throws -> StartDeviceAuthorizationOutput
    func createToken(_ input: CreateTokenInput) async throws -> CreateTokenOutput
}

public protocol SSOClienting: Sendable {
    func getRoleCredentials(_ input: GetRoleCredentialsInput) async throws -> GetRoleCredentialsOutput
}

extension SSOOIDCClient: SSOOIDCClienting {
    public func registerClient(_ input: RegisterClientInput) async throws -> RegisterClientOutput {
        try await registerClient(input: input)
    }
    public func startDeviceAuthorization(_ input: StartDeviceAuthorizationInput) async throws -> StartDeviceAuthorizationOutput {
        try await startDeviceAuthorization(input: input)
    }
    public func createToken(_ input: CreateTokenInput) async throws -> CreateTokenOutput {
        try await createToken(input: input)
    }
}

extension SSOClient: SSOClienting {
    public func getRoleCredentials(_ input: GetRoleCredentialsInput) async throws -> GetRoleCredentialsOutput {
        try await getRoleCredentials(input: input)
    }
}
