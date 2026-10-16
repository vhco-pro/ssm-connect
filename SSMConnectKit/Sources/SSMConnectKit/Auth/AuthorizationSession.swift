import Foundation
import Observation

@MainActor @Observable
public final class AuthorizationSession: AuthProviding {
    enum Status: Equatable {
        case idle, ready, refreshing, signInRequired, signingIn
        case unavailable(String)
    }

    private(set) var status: Status = .idle
    private(set) var credentialsExpiry: Date?
    private(set) var metadata: AuthorizationMetadata?
    private(set) var profile: ConnectionProfile
    private let provider: AuthProviding
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private let leadTime: TimeInterval
    private var credentials: AWSCredentials?
    private var request: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var generation = 0
    private var waiters: [UUID: CheckedContinuation<AWSCredentials, Error>] = [:]

    public convenience init(profile: ConnectionProfile) {
        self.init(profile: profile, provider: AWSAuthProvider())
    }

    init(profile: ConnectionProfile, provider: AuthProviding,
         now: @escaping @Sendable () -> Date = { Date() },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         leadTime: TimeInterval = 300) {
        self.profile = profile
        self.provider = provider
        self.now = now
        self.sleep = sleep
        self.leadTime = leadTime
        AppQuitHandler.shared.register { [weak self] in self?.cancel() }
    }

    var detailLine: String? {
        switch status {
        case .idle: return nil
        case .ready:
            return "Authorization ready for new operations. SSO session deadline is unknown."
        case .refreshing: return "Renewing authorization; established connections are unchanged."
        case .signingIn: return "Signing in with SSO; pending operations will resume."
        case .signInRequired:
            if let metadata, !metadata.canRefresh {
                return "Sign In Required. Cached access token expires \(metadata.accessTokenExpiry.formatted(date: .omitted, time: .shortened)); SSO session deadline is unknown."
            }
            return "Sign In Required for new operations. Established connections are unchanged."
        case let .unavailable(message): return message
        }
    }

    public func apply(profile: ConnectionProfile) {
        guard profile != self.profile else { return }
        cancel()
        self.profile = profile
        credentials = nil
        credentialsExpiry = nil
        metadata = nil
        status = .idle
    }

    func retaining(profile: ConnectionProfile) -> AuthorizationSession {
        let retained = AuthorizationSession(profile: profile, provider: provider, now: now, sleep: sleep, leadTime: leadTime)
        if self.profile == profile {
            retained.credentials = credentials
            retained.credentialsExpiry = credentialsExpiry
            retained.metadata = metadata
            retained.status = status == .ready ? .ready : .idle
            if retained.credentials != nil { retained.scheduleRenewal() }
        }
        return retained
    }

    func cancel() {
        generation += 1
        request?.cancel()
        renewal?.cancel()
        request = nil
        renewal = nil
        completeWaiters(.failure(CancellationError()))
    }

    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials {
        try checkProfile(profile)
        if let credentials, credentials.expiration > now(), status == .ready { return credentials }
        if request == nil, status != .signInRequired { startRequest(interactive: false) }
        return try await waitForCredentials()
    }

    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        try checkProfile(profile)
        if status == .signInRequired { throw AuthError.signInRequired }
        if request == nil { startRequest(interactive: false) }
        return try await waitForCredentials()
    }

    func signIn(profile: ConnectionProfile) async throws -> AWSCredentials {
        try checkProfile(profile)
        signIn()
        return try await waitForCredentials()
    }

    func signIn() {
        guard status != .signingIn else { return }
        request?.cancel()
        startRequest(interactive: true)
    }

    func retry() {
        guard request == nil else { return }
        startRequest(interactive: false)
    }

    func requireSignIn() {
        credentials = nil
        renewal?.cancel()
        renewal = nil
        status = .signInRequired
    }

    func authorizationMetadata(profile: ConnectionProfile) async throws -> AuthorizationMetadata? {
        try checkProfile(profile)
        return metadata
    }

    func recover(profile: ConnectionProfile) async throws -> AWSCredentials {
        try checkProfile(profile)
        credentials = nil
        if request == nil, status != .signInRequired { startRequest(interactive: false) }
        return try await waitForCredentials()
    }

    func checkFreshness() {
        guard request == nil else { return }
        let date = now()
        if let metadata, !metadata.canRefresh,
           metadata.accessTokenExpiry.timeIntervalSince(date) <= leadTime {
            status = .signInRequired
            renewal?.cancel()
            renewal = nil
            return
        }
        let deadlines = [credentialsExpiry, metadata?.accessTokenExpiry].compactMap { $0 }
        guard deadlines.contains(where: { $0.timeIntervalSince(date) <= leadTime }) else { return }
        startRequest(interactive: false)
    }

    func withCredentials<T>(profile: ConnectionProfile,
                            operation: (AWSCredentials) async throws -> T) async throws -> T {
        let credentials = try await authenticate(profile: profile)
        try checkProfile(profile)
        do {
            return try await operation(credentials)
        } catch {
            guard AWSAuthProvider.isRejectedAuthorization(error) else { throw error }
            let fresh = try await recover(profile: profile)
            try checkProfile(profile)
            do { return try await operation(fresh) }
            catch {
                guard AWSAuthProvider.isRejectedAuthorization(error) else { throw error }
                requireSignIn()
                throw AuthError.signInRequired
            }
        }
    }

    private func checkProfile(_ profile: ConnectionProfile) throws {
        try Task.checkCancellation()
        guard profile == self.profile else { throw CancellationError() }
    }

    private func waitForCredentials() async throws -> AWSCredentials {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        if waiters.isEmpty, status == .signingIn {
            generation += 1
            request?.cancel()
            request = nil
            status = .signInRequired
        }
    }

    private func startRequest(interactive: Bool) {
        generation += 1
        let generation = generation
        let profile = profile
        let provider = provider
        renewal?.cancel()
        renewal = nil
        status = interactive ? .signingIn : .refreshing
        request = Task { [weak self] in
            do {
                let previousMetadata = try await provider.authorizationMetadata(profile: profile)
                guard let self, self.generation == generation else { return }
                self.metadata = previousMetadata
                let credentials = try await withStageTimeout("SSO authorization", .seconds(300)) {
                    if interactive { return try await provider.signIn(profile: profile) }
                    return try await provider.refreshIfNeeded(profile: profile)
                }
                try Task.checkCancellation()
                let metadata = try await provider.authorizationMetadata(profile: profile)
                guard self.generation == generation else { return }
                guard credentials.expiration > self.now() else { throw AuthError.missingRoleCredentials }
                self.credentials = credentials
                self.credentialsExpiry = credentials.expiration
                self.metadata = metadata
                self.status = .ready
                self.request = nil
                self.completeWaiters(.success(credentials))
                self.scheduleRenewal()
            } catch {
                guard let self, self.generation == generation else { return }
                self.request = nil
                if AWSAuthProvider.isRejectedAuthorization(error) {
                    self.status = .signInRequired
                } else {
                    let message: String
                    if let authError = error as? AuthError {
                        message = authError.localizedDescription
                    } else if error is CancellationError {
                        message = "Authorization was cancelled."
                    } else if error is URLError {
                        message = "Authorization is unavailable. Check your network and retry; existing connections are unchanged."
                    } else {
                        message = "Authorization could not be renewed. Retry authorization or check access to this account and role; existing connections are unchanged."
                    }

                    self.status = .unavailable(message)
                    self.completeWaiters(.failure(error))
                }
            }
        }
    }

    private func scheduleRenewal() {
        let deadlines = [credentialsExpiry, metadata?.accessTokenExpiry].compactMap { $0 }
        guard let deadline = deadlines.min() else { return }
        // A short-lived response must not cause a tight refresh loop.
        let delay = max(30, deadline.timeIntervalSince(now()) - leadTime)
        let sleep = sleep
        renewal = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                try Task.checkCancellation()
                self?.checkFreshness()
            } catch is CancellationError {
                return
            } catch {
                self?.status = .unavailable("Authorization renewal could not be scheduled. Retry authorization.")
            }
        }
    }

    private func completeWaiters(_ result: Result<AWSCredentials, Error>) {
        let continuations = Array(waiters.values)
        waiters.removeAll()
        for continuation in continuations { continuation.resume(with: result) }
    }
}

extension AuthProviding {
    @MainActor
    func authorized<T>(profile: ConnectionProfile, credentials: AWSCredentials,
                       operation: (AWSCredentials) async throws -> T) async throws -> T {
        try Task.checkCancellation()
        if let session = self as? AuthorizationSession {
            return try await session.withCredentials(profile: profile, operation: operation)
        }
        return try await operation(credentials)
    }
}
