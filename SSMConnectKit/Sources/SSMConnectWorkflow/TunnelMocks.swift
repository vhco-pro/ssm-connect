import Foundation
import SSMConnectDomain

/// In-memory `SSMProviding` test double for higher-level (state-machine) tests (D8).
package final class MockSSMService: SSMProviding, @unchecked Sendable {
    package var waitError: Error?
    package var onWaitForSSMOnline: (@Sendable (Duration) async throws -> Void)?
    package var startSessionResult: Result<SSMSessionResponse, Error> = .success(.stub())

    package private(set) var waitCount = 0
    package private(set) var startSessionCount = 0
    package private(set) var lastLocalPort: Int?
    package private(set) var lastRemotePort: Int?
    package private(set) var startSSHSessionCount = 0
    package var onStartSSHSession: (@Sendable () -> Void)?

    package func startSSHSession(
        instanceId: String, region: String, credentials: AWSCredentials
    ) async throws -> SSMSessionResponse {
        startSSHSessionCount += 1
        onStartSSHSession?()
        return try startSessionResult.get()
    }

    package func waitForSSMOnline(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws {
        waitCount += 1
        try await onWaitForSSMOnline?(timeout)
        if let waitError { throw waitError }
    }

    package func startSession(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        localPort: Int,
        remotePort: Int
    ) async throws -> SSMSessionResponse {
        startSessionCount += 1
        lastLocalPort = localPort
        lastRemotePort = remotePort
        return try startSessionResult.get()
    }

    package init() {}
}

/// In-memory `TunnelProvider` / `TunnelHandle` test doubles (D8).
package final class MockTunnelProvider: TunnelProvider, @unchecked Sendable {
    package var availability: TunnelProviderStatus = .available
    package var startResult: Result<TunnelHandle, Error>?

    package private(set) var startCount = 0

    package func checkAvailability() -> TunnelProviderStatus { availability }

    package func startTunnel(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) async throws -> TunnelHandle {
        startCount += 1
        if let startResult { return try startResult.get() }
        return MockTunnelHandle()
    }

    package init() {}
}

package final class MockTunnelHandle: TunnelHandle, @unchecked Sendable {
    package var isActive: Bool = true
    package var processIdentifier: Int32? = 4242
    package private(set) var terminateCount = 0
    private let continuation: AsyncStream<TunnelDropReason>.Continuation
    package let onDisconnect: AsyncStream<TunnelDropReason>

    package init() {
        var captured: AsyncStream<TunnelDropReason>.Continuation!
        onDisconnect = AsyncStream { captured = $0 }
        continuation = captured
    }

    package func terminate() async {
        terminateCount += 1
        isActive = false
        continuation.yield(.terminatedByUser)
        continuation.finish()
    }

    /// Test helper: simulate the plugin process exiting unexpectedly.
    package func simulateDrop(code: Int32 = 1, stderr: String = "") {
        isActive = false
        continuation.yield(.processExited(code: code, stderr: stderr))
        continuation.finish()
    }
}

extension SSMSessionResponse {
    package static func stub(
        sessionId: String = "example-session-0abc1234",
        streamUrl: String = "wss://ssmmessages.us-east-1.amazonaws.com/v1/data-channel/example-session-0abc1234?role=publish_subscribe",
        tokenValue: String = "AAEAAfEXAMPLE"
    ) -> SSMSessionResponse {
        SSMSessionResponse(sessionId: sessionId, streamUrl: streamUrl, tokenValue: tokenValue)
    }
}
