import Foundation
import Testing
@testable import SSMConnectKit

private final class AuthorizationClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return date }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; date.addTimeInterval(seconds) }
}

@MainActor
private final class SessionAuthProvider: AuthProviding {
    var credentials: AWSCredentials
    var metadata: AuthorizationMetadata?
    var silentError: Error?
    var holdLogin = false
    private(set) var silentCount = 0
    private(set) var loginCount = 0
    private(set) var authenticatedProfiles: [ConnectionProfile] = []

    init(now: Date) {
        credentials = AWSCredentials(accessKeyId: "fixture", secretAccessKey: "fixture", sessionToken: "fixture",
                                     expiration: now.addingTimeInterval(3600))
    }

    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials { try await signIn(profile: profile) }
    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        silentCount += 1
        authenticatedProfiles.append(profile)
        if let silentError { throw silentError }
        return credentials
    }
    func signIn(profile: ConnectionProfile) async throws -> AWSCredentials {
        loginCount += 1
        authenticatedProfiles.append(profile)
        while holdLogin { try await Task.sleep(for: .milliseconds(1)) }
        try Task.checkCancellation()
        return credentials
    }
    func authorizationMetadata(profile: ConnectionProfile) async throws -> AuthorizationMetadata? { metadata }
}

@Suite("Authorization freshness and recovery")
@MainActor
struct AuthorizationSessionTests {
    private let profile = ConnectionProfile.example
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test("AUTH-01: Known expiry approaches and silent renewal succeeds")
    func proactiveRenewalIsDeduplicated() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        _ = try await session.authenticate(profile: profile)
        clock.advance(3301)
        provider.credentials = AWSCredentials(accessKeyId: "renewed", secretAccessKey: "fixture", sessionToken: "fixture",
                                             expiration: clock.now().addingTimeInterval(3600))
        session.checkFreshness()
        session.checkFreshness()
        try await wait { session.status == .ready && provider.silentCount == 2 }
        #expect(provider.loginCount == 0)
        #expect(session.credentialsExpiry == provider.credentials.expiration)
    }

    @Test("AUTH-02: Silent renewal is rejected or authorization is not renewable")
    func knownNonrenewableDeadlineIsVisible() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.metadata = .init(accessTokenExpiry: clock.now().addingTimeInterval(600), canRefresh: false)
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        _ = try await session.authenticate(profile: profile)
        clock.advance(301)
        session.checkFreshness()
        #expect(session.status == .signInRequired)
        #expect(session.detailLine?.contains("Cached access token expires") == true)
        #expect(session.detailLine?.contains("SSO session deadline is unknown") == true)
        #expect(provider.silentCount == 1)
        #expect(provider.loginCount == 0)
    }

    @Test("AUTH-03: Owner signs in with editor/browser work pending")
    func oneLoginResumesSameTargetOperations() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.silentError = AuthError.signInRequired
        provider.holdLogin = true
        let profile = ConnectionProfile.example
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        var resumed: [String] = []
        let editor = Task {
            try await session.withCredentials(profile: profile) { _ in resumed.append("editor"); return profile.id }
        }
        let browser = Task {
            try await session.withCredentials(profile: profile) { _ in resumed.append("browser"); return profile.id }
        }
        try await wait { session.status == .signInRequired }
        #expect(resumed.isEmpty)
        session.signIn()
        session.signIn()
        try await wait { provider.loginCount == 1 }
        provider.holdLogin = false
        #expect(try await editor.value == profile.id)
        #expect(try await browser.value == profile.id)
        #expect(Set(resumed) == ["editor", "browser"])
        #expect(provider.silentCount == 1)
        #expect(provider.loginCount == 1)
    }

    @Test("AUTH-04: Authorization is revoked unexpectedly")
    func rejectedOperationWaitsForExplicitSignInOnce() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        _ = try await session.authenticate(profile: profile)
        provider.silentError = AuthError.signInRequired
        var attempts = 0
        let operation = Task {
            try await session.withCredentials(profile: profile) { _ in
                attempts += 1
                if attempts == 1 { throw AuthError.signInRequired }
                return "same-target"
            }
        }
        try await wait { session.status == .signInRequired }
        #expect(attempts == 1)
        #expect(provider.loginCount == 0)
        session.signIn()
        #expect(try await operation.value == "same-target")
        #expect(attempts == 2)
        #expect(provider.silentCount == 2)
        #expect(provider.loginCount == 1)
    }

    @Test("AUTH-04: Repeated rejection is bounded and remains actionable")
    func repeatedRejectionDoesNotLoop() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        var attempts = 0
        await #expect(throws: AuthError.signInRequired) {
            try await session.withCredentials(profile: profile) { _ -> String in
                attempts += 1
                throw AuthError.signInRequired
            }
        }
        #expect(attempts == 2)
        #expect(session.status == .signInRequired)
        #expect(provider.silentCount == 2)
        #expect(provider.loginCount == 0)
    }

    @Test("AUTH-05: Profile changes or Stop occurs during login", arguments: [false, true])
    func changedOrStoppedTargetNeverResumes(changeProfile: Bool) async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.silentError = AuthError.signInRequired
        provider.holdLogin = true
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        var resumed = false
        let operation = Task {
            try await session.withCredentials(profile: profile) { _ in resumed = true }
        }
        try await wait { session.status == .signInRequired }
        session.signIn()
        try await wait { provider.loginCount == 1 }
        if changeProfile {
            var other = ConnectionProfile.example
            other.instanceTagValue = "different-workstation"
            session.apply(profile: other)
        } else {
            operation.cancel()
        }
        provider.holdLogin = false
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(!resumed)
    }

    @Test("AUTH-06: Existing channel survives credential expiry")
    func signInWarningDoesNotTearDownHealthyTunnel() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.metadata = .init(accessTokenExpiry: clock.now().addingTimeInterval(600), canRefresh: false)
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        let tunnel = RecordingTunnelProvider(handles: [])
        let machine = ConnectionStateMachine(authProvider: session, ec2: MockEC2Service(), ssm: MockSSMService(),
            tunnel: tunnel, secrets: MockSecretsService(), dcv: MockDCVLauncher(), readiness: StubReadinessProbe(),
            tunnelListener: StubTunnelListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
            notifier: MockNotifier(), profile: profile)
        machine.connect()
        await machine.awaitInFlightTask()
        try #require(machine.state == .connected)
        let pid = machine.tunnelPID
        clock.advance(601)
        session.checkFreshness()
        #expect(session.status == .signInRequired)
        #expect(machine.state == .connected)
        #expect(machine.tunnelPID == pid)
        #expect(tunnel.startCount == 1)
        #expect(tunnel.issuedHandles.first?.isActive == true)
        machine.disconnect()
        await machine.awaitInFlightTask()
        session.cancel()
    }

    @Test("AUTH-07: Offline or permission-set access is denied", arguments: [false, true])
    func networkAndAccessFailuresDoNotPromptForLogin(accessDenied: Bool) async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.silentError = accessDenied
            ? AuthError.roleAccessDenied(accountId: "123456789012", roleName: "TestRole", detail: nil)
            : URLError(.notConnectedToInternet)
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        defer { session.cancel() }
        do {
            _ = try await session.authenticate(profile: profile)
            Issue.record("Expected an actionable authorization failure")
        } catch {
            if accessDenied { #expect(error is AuthError) }
            else { #expect(error is URLError) }
        }
        guard case let .unavailable(message) = session.status else {
            Issue.record("Expected an unavailable state, not a sign-in prompt")
            return
        }
        #expect(message.contains(accessDenied ? "No access to account" : "Check your network"))
        #expect(provider.silentCount == 1)
        #expect(provider.loginCount == 0)
    }

    @Test("AUTH-03: One SSO action resumes actual desktop and browser preparation")
    func sharedSessionResumesBothStateMachines() async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        provider.silentError = AuthError.signInRequired
        let profile = portableExample()
        let session = AuthorizationSession(profile: profile, provider: provider, now: { clock.now() })
        let machine = ConnectionStateMachine(authProvider: session, ec2: MockEC2Service(), ssm: MockSSMService(),
            tunnel: MockTunnelProvider(), secrets: MockSecretsService(), dcv: MockDCVLauncher(),
            readiness: StubReadinessProbe(), tunnelListener: StubTunnelListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
            notifier: MockNotifier(), profile: profile)
        let recorder = WebEventRecorder()
        let web = WebForwardsStateMachine(profile: profile, auth: session, ec2: MockEC2Service(),
            ssm: MockSSMService(), instanceConnect: FakeInstanceConnect(recorder),
            keyGenerator: FakeSSHKeyGenerator(recorder: recorder), tunnel: FakeSSHTunnel(recorder),
            writePAC: { _, _ in URL(fileURLWithPath: "/tmp/unused-profile-fixture.pac") })
        let browser = FakeBrowserOpening()
        machine.connect()
        web.openBrowser(using: browser)
        try await wait { session.status == .signInRequired }
        #expect(browser.launchCount == 0)
        session.signIn()
        await machine.awaitInFlightTask()
        await web.awaitBrowserOpened()
        #expect(machine.state == .connected)
        #expect(web.state == .on)
        #expect(browser.launchCount == 1)
        #expect(provider.loginCount == 1)
        web.stop()
        machine.disconnect()
        await web.awaitStopped()
        await machine.awaitInFlightTask()
        session.cancel()
    }

    @Test("AUTH-05 and AUTH-06: Connected profile edits preserve active authorization until explicit adoption",
          arguments: ["reconnect", "stop", "disconnect", "wake"], [false, true])
    func connectedProfileEditsDoNotStrandActions(action: String, changedTarget: Bool) async throws {
        let clock = AuthorizationClock()
        let provider = SessionAuthProvider(now: clock.now())
        var original = profile
        original.connectAction = .tunnelOnly
        let session = AuthorizationSession(profile: original, provider: provider, now: { clock.now() })
        let tunnel = RecordingTunnelProvider(handles: [])
        let ec2 = MockEC2Service()
        let machine = ConnectionStateMachine(authProvider: session, ec2: ec2, ssm: MockSSMService(), tunnel: tunnel,
            secrets: MockSecretsService(), dcv: MockDCVLauncher(), readiness: StubReadinessProbe(ready: false),
            tunnelListener: StubTunnelListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
            notifier: MockNotifier(), profile: original)
        machine.connect()
        await machine.awaitInFlightTask()
        try #require(machine.state == .connected)
        let handle = try #require(tunnel.issuedHandles.first)
        var saved = original
        saved.name = "Saved name"
        if changedTarget { saved.roleName = "OtherRole"; saved.instanceTagValue = "other-workstation" }
        machine.apply(profile: saved, settings: .default)
        #expect(machine.profile == original)
        #expect(machine.pendingProfile == saved)
        #expect(handle.isActive)
        #expect(machine.authorizationSession?.profile == original)
        #expect(session.profile == saved)
        switch action {
        case "reconnect":
            machine.reconnect()
            await machine.awaitInFlightTask()
            #expect(machine.state == .connected)
            #expect(machine.profile == saved)
            #expect(provider.authenticatedProfiles.last == saved)
        case "stop":
            machine.stopWorkstation()
            await machine.awaitInFlightTask()
            #expect(machine.state == .disconnected)
            #expect(ec2.stopCount == 1)
            #expect(machine.profile == saved)
        case "disconnect":
            machine.disconnect()
            await machine.awaitInFlightTask()
            #expect(machine.state == .disconnected)
            #expect(machine.profile == saved)
        default:
            await machine.handleSystemWake()
            await machine.awaitInFlightTask()
            #expect(machine.state == .connected)
            #expect(machine.profile == original)
            #expect(machine.pendingProfile == saved)
            #expect(provider.authenticatedProfiles.last == original)
        }
        machine.disconnect()
        await machine.awaitInFlightTask()
        session.cancel()
    }
}
