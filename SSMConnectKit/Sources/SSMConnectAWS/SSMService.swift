import AWSSSM
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Default `SSMProviding` backed by `aws-sdk-swift`'s `SSMClient` (D2).
///
/// Polls SSM until the instance's agent is `Online`, then opens a port-forwarding session.
public final class SSMService: SSMProviding {
    public typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> SSMClienting

    /// SSM document for local port forwarding (spec §6.4).
    public static let portForwardDocument = SSMDocument.portForward

    /// Resolves the caller's own ARN, so a reap only ever touches this caller's sessions.
    public typealias CallerARNResolver = @Sendable (_ credentials: AWSCredentials, _ region: String) async throws -> String

    private let makeClient: ClientFactory
    private let callerARN: CallerARNResolver

    public init(
        makeClient: @escaping ClientFactory = { try SSMClientFactory.make(credentials: $0, region: $1) },
        callerARN: @escaping CallerARNResolver = SSMService.defaultCallerARN
    ) {
        self.makeClient = makeClient
        self.callerARN = callerARN
    }

    /// The caller ARN via a presigned `sts:GetCallerIdentity`, reusing the primitive the multi-user
    /// path already depends on rather than pulling in the STS SDK for one field.
    public static let defaultCallerARN: CallerARNResolver = { credentials, region in
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: region))
        let (arn, _) = try await resolver.resolve(credentials: credentials)
        return arn
    }

    // MARK: - SSMProviding

    public func waitForSSMOnline(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws {
        let client = try makeClient(credentials, region)
        let input = DescribeInstanceInformationInput(filters: [
            .init(key: "InstanceIds", values: [instanceId]),
        ])
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let output = try await client.describeInstanceInformation(input)
            let isOnline = (output.instanceInformationList ?? [])
                .contains { $0.instanceId == instanceId && $0.pingStatus == .online }
            if isOnline { return }
            try await Task.sleep(for: interval)
        }
        throw SSMError.notOnlineInTime(instanceId: instanceId)
    }

    public func startSession(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        localPort: Int,
        remotePort: Int
    ) async throws -> SSMSessionResponse {
        let client = try makeClient(credentials, region)
        let input = StartSessionInput(
            documentName: Self.portForwardDocument,
            parameters: [
                "portNumber": [String(remotePort)],
                "localPortNumber": [String(localPort)],
            ],
            target: instanceId
        )
        let output = try await client.startSession(input)
        guard
            let sessionId = output.sessionId,
            let streamUrl = output.streamUrl,
            let tokenValue = output.tokenValue
        else {
            throw SSMError.malformedSessionResponse
        }
        return SSMSessionResponse(sessionId: sessionId, streamUrl: streamUrl, tokenValue: tokenValue)
    }

    // MARK: - Session hygiene (AC-07)

    public func reapOrphanedSessions(
        instanceId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> Int {
        let arn = try await callerARN(credentials, region)
        let client = try makeClient(credentials, region)
        // `.targetId` is the SDK's spelling of the API's `Target` filter — the same one the .NET
        // client uses, so both reap against an identical query.
        let output = try await client.describeSessions(DescribeSessionsInput(
            filters: [SSMClientTypes.SessionFilter(key: .targetId, value: instanceId)],
            state: .active
        ))

        // The caller ARN is an assumed-role ARN and the session owner is reported in the same
        // shape, so an exact comparison is the right test. Anything looser risks terminating a
        // colleague's session on a shared multi-user workstation.
        let mine = (output.sessions ?? []).filter { $0.owner == arn }
        var reaped = 0
        for session in mine {
            guard let sessionId = session.sessionId else { continue }
            _ = try await client.terminateSession(TerminateSessionInput(sessionId: sessionId))
            reaped += 1
        }
        return reaped
    }

    public func terminateSession(
        sessionId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws {
        let client = try makeClient(credentials, region)
        _ = try await client.terminateSession(TerminateSessionInput(sessionId: sessionId))
    }
}
