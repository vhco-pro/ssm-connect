import Foundation

/// Configurable `AuthProviding` test double (B6, ADR-P2). Lets tests and previews drive
/// success/failure/delay without the network or a browser.
final class MockAuthProvider: AuthProviding, @unchecked Sendable {
    enum Outcome: Sendable {
        case success(AWSCredentials)
        case failure(any Error)
    }

    var authenticateOutcome: Outcome
    var refreshOutcome: Outcome
    /// Artificial delay applied before returning, to exercise transitional UI states.
    var delay: Duration

    private(set) var authenticateCallCount = 0
    private(set) var refreshCallCount = 0

    init(
        authenticateOutcome: Outcome = .success(.stub),
        refreshOutcome: Outcome = .success(.stub),
        delay: Duration = .zero
    ) {
        self.authenticateOutcome = authenticateOutcome
        self.refreshOutcome = refreshOutcome
        self.delay = delay
    }

    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials {
        authenticateCallCount += 1
        return try await resolve(authenticateOutcome)
    }

    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        refreshCallCount += 1
        return try await resolve(refreshOutcome)
    }

    private func resolve(_ outcome: Outcome) async throws -> AWSCredentials {
        if delay > .zero { try await Task.sleep(for: delay) }
        switch outcome {
        case let .success(credentials): return credentials
        case let .failure(error): throw error
        }
    }
}

extension AWSCredentials {
    /// Non-secret placeholder credentials for tests/previews (valid for one hour).
    static let stub = AWSCredentials(
        accessKeyId: "ASIAEXAMPLE",
        secretAccessKey: "wJalrXUtnFEMI/EXAMPLEKEY",
        sessionToken: "FwoGZXIvYXdzEXAMPLE",
        expiration: Date().addingTimeInterval(3600)
    )
}
