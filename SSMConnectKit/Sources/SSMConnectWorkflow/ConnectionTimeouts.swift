import Foundation
import SSMConnectDomain

/// Per-stage timeout budget for the connection flow (spec §5 timing table, F-06).
package struct ConnectionTimeouts: Sendable {
    package var authenticate: Duration = .seconds(300)   // 5 min browser login
    package var resolve: Duration = .seconds(30)
    package var start: Duration = .seconds(300)          // 5 min instance start
    package var startPollInterval: Duration = .seconds(5)
    package var ssm: Duration = .seconds(180)            // 3 min SSM registration
    package var ssmPollInterval: Duration = .seconds(5)
    package var tunnel: Duration = .seconds(30)
    /// Wait for the in-VM DCV server to start accepting connections after the tunnel is up
    /// (SSM-agent-Online ≠ DCV-server-ready).
    package var dcvReady: Duration = .seconds(30)
    package var dcvReadyPollInterval: Duration = .seconds(1)
    /// Budget for the tunnel-up TCP assertion before the readiness probe (#9, RVL-3).
    package var tunnelListen: Duration = .seconds(3)
    /// How many times to tear down + re-establish the tunnel on a pre-launch readiness failure
    /// before surfacing a retryable error (#9, RVL-5). 2 retries → 3 attempts total.
    package var establishRetryAttempts: Int = 2
    /// Base backoff between RVL-5 re-establish attempts; multiplied by the attempt number (2s, 4s).
    package var establishRetryBackoff: Duration = .seconds(2)

    package static let `default` = ConnectionTimeouts()

    package init(authenticate: Duration = .seconds(300), resolve: Duration = .seconds(30), start: Duration = .seconds(300), startPollInterval: Duration = .seconds(5), ssm: Duration = .seconds(180), ssmPollInterval: Duration = .seconds(5), tunnel: Duration = .seconds(30), dcvReady: Duration = .seconds(30), dcvReadyPollInterval: Duration = .seconds(1), tunnelListen: Duration = .seconds(3), establishRetryAttempts: Int = 2, establishRetryBackoff: Duration = .seconds(2)) {
        self.authenticate = authenticate
        self.resolve = resolve
        self.start = start
        self.startPollInterval = startPollInterval
        self.ssm = ssm
        self.ssmPollInterval = ssmPollInterval
        self.tunnel = tunnel
        self.dcvReady = dcvReady
        self.dcvReadyPollInterval = dcvReadyPollInterval
        self.tunnelListen = tunnelListen
        self.establishRetryAttempts = establishRetryAttempts
        self.establishRetryBackoff = establishRetryBackoff
    }
}

/// Thrown when a connection stage exceeds its timeout budget (F-06).
package struct StageTimeoutError: LocalizedError, Equatable {
    package let stage: String
    package var errorDescription: String? { "\(stage) timed out." }

    package init(stage: String) {
        self.stage = stage
    }
}

/// Run `operation`, throwing `StageTimeoutError` if it doesn't finish within `duration`.
/// The losing child task is cancelled.
package func withStageTimeout<T: Sendable>(
    _ stage: String,
    _ duration: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(duration)
            throw StageTimeoutError(stage: stage)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw StageTimeoutError(stage: stage)
        }
        return result
    }
}
