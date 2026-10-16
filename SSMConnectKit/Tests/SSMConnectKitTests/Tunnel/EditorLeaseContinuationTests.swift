import Foundation
import Testing
@testable import SSMConnectKit

@MainActor
private final class LeaseClock {
    var date = Date()
    func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
}

private actor LeaseSleeper {
    private var pending: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        durations.append(duration)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { pending.append((id, duration, $0)) }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func resume(_ duration: Duration) {
        guard let index = pending.firstIndex(where: { $0.1 == duration }) else { return }
        pending.remove(at: index).2.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = pending.firstIndex(where: { $0.0 == id }) else { return }
        pending.remove(at: index).2.resume(throwing: CancellationError())
    }
}

@MainActor
private final class LeaseEC2: EC2Providing {
    var instance = EC2Instance.stub(state: .running)
    var onResolve: (() async throws -> Void)?
    private(set) var resolves = 0
    private(set) var starts = 0
    private(set) var stops = 0
    func resolveInstance(tagKey: String, tagValue: String, region: String, credentials: AWSCredentials) async throws -> EC2Instance {
        resolves += 1
        try await onResolve?()
        return instance
    }
    func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws { starts += 1 }
    func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws { stops += 1 }
    func pollUntilRunning(instanceId: String, region: String, credentials: AWSCredentials,
                          timeout: Duration, interval: Duration) async throws -> EC2Instance { instance }
}

private struct LeaseKeyGenerator: SSHKeyGenerating {
    let root: URL
    let recorder: WebEventRecorder
    func generate() async throws -> SSHKeyMaterial {
        recorder.append("key")
        let directory = root.appendingPathComponent(UUID().uuidString)
        try BrowserPrivateFiles.directory(directory)
        try BrowserPrivateFiles.write(Data("fixture-private-key".utf8), to: directory.appendingPathComponent("key"))
        let publicKey = "ssh-ed25519 fixture"
        try BrowserPrivateFiles.write(Data(publicKey.utf8), to: directory.appendingPathComponent("key.pub"))
        return SSHKeyMaterial(directory: directory, publicKey: publicKey)
    }
}

private final class LeaseMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var current: RemoteSSHLease
    private var date: Date
    private var active = true
    let original: RemoteSSHLease

    init(_ lease: RemoteSSHLease) { original = lease; current = lease; date = lease.expiresAt.addingTimeInterval(-1) }
    func renewed(_ lease: RemoteSSHLease) {
        lock.lock(); defer { lock.unlock() }
        current = lease
        date = original.expiresAt.addingTimeInterval(1)
    }
    func revoke() { lock.lock(); defer { lock.unlock() }; active = false }
    func isCurrent() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current.continues(original, ownerActive: active, now: date)
    }
}

@MainActor
private final class LeaseFixture {
    let root: URL
    let clock = LeaseClock()
    let auth = MockAuthProvider()
    let ec2 = LeaseEC2()
    let ssm = MockSSMService()
    let recorder = WebEventRecorder()
    var owner: (pid: Int32, launchDate: Date, bundleID: String)? = (12345, Date(), "lease-fixture")
    var writeError: Error?
    private(set) var writes = 0
    private(set) var launches = 0
    var beforeWrite: (() throws -> Void)?
    var profile = ConnectionProfile.example
    var machine: RemoteDevelopmentStateMachine!

    init(sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-lease-fixture-" + UUID().uuidString)
        try BrowserPrivateFiles.directory(root)
        profile.remoteDevelopment = .init(enabled: true)
        profile.webForwards = .init(sshUser: "example")
        let recorder = recorder
        machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("access"),
            configURL: root.appendingPathComponent("user/config"), auth: auth, ec2: ec2, ssm: ssm,
            keyGenerator: LeaseKeyGenerator(root: root.appendingPathComponent("keys"), recorder: recorder),
            helperPath: { "/usr/bin/true" }, pluginPath: { "/usr/bin/true" },
            editorPath: { "/usr/bin/true" }, editorPreflight: { _ in },
            ownerIdentity: { [weak self] in self?.owner }, now: { [clock] in clock.date },
            renewalSleep: sleep, writeLease: { [weak self] data, url in
                guard let self else { throw CancellationError() }
                if let writeError = self.writeError { throw writeError }
                try self.beforeWrite?()
                try BrowserPrivateFiles.write(data, to: url)
                self.writes += 1
            }, launchEditor: { [weak self] _, _ in self?.launches += 1 })
        try machine.installSetup(consent: true)
        let credentials = AWSCredentials(accessKeyId: "fixture", secretAccessKey: "fixture", sessionToken: "fixture",
                                         expiration: clock.date.addingTimeInterval(10 * 24 * 60 * 60))
        auth.authenticateOutcome = .success(credentials)
        auth.refreshOutcome = .success(credentials)
    }

    var leaseURL: URL { root.appendingPathComponent("access/\(profile.id.uuidString)/lease.json") }
    func lease() throws -> RemoteSSHLease { try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL)) }
    func open() async throws {
        machine.open()
        await machine.awaitOpening()
        try #require(machine.errorMessage == nil)
        try #require(machine.editorLaunched)
    }
    func cleanup() {
        machine.stop()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not clean owned lease fixture: \(error.localizedDescription)") }
    }
}

@Suite("Rolling editor lease continuation")
@MainActor
struct EditorLeaseContinuationTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    private func waitAsync(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await condition())
    }

    @Test("LEASE-01: Same-owner editor remains open across its original lease deadline")
    func automaticTimerRenewsSameGenerationWithoutOpeningEditor() async throws {
        let sleeper = LeaseSleeper()
        let fixture = try LeaseFixture(sleep: { try await sleeper.sleep($0) })
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        try await waitAsync { !(await sleeper.durations.isEmpty) }
        #expect(await sleeper.durations.first == .seconds(24 * 60 * 60 - 300))
        fixture.clock.advance(24 * 60 * 60 - 300)
        await sleeper.resume(.seconds(24 * 60 * 60 - 300))
        try await wait { fixture.writes == 2 }
        await fixture.machine.awaitLeaseRenewal()
        let renewed = try fixture.lease()
        #expect(renewed.expiresAt == fixture.clock.date.addingTimeInterval(24 * 60 * 60))
        #expect(renewed.generation == original.generation)
        #expect(renewed.keyPath == original.keyPath)
        #expect(renewed.ownerLaunchDate == original.ownerLaunchDate)
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(fixture.launches == 1 && fixture.recorder.values == ["key"])
        fixture.clock.advance(301)
        #expect(renewed.continues(original, ownerActive: true, now: fixture.clock.date))
        #expect(fixture.ec2.starts == 0 && fixture.ec2.stops == 0)
    }

    @Test("LEASE-01 and LEASE-02: Renewal starts exactly at the five-minute boundary and is deduplicated")
    func exactBoundaryAndConcurrentTriggers() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.clock.advance(24 * 60 * 60 - 301)
        fixture.machine.checkLeaseContinuation()
        #expect(!fixture.machine.isRenewingLease && fixture.auth.refreshCallCount == 0)
        fixture.clock.advance(1)
        fixture.machine.checkLeaseContinuation()
        fixture.machine.checkLeaseContinuation()
        fixture.machine.renewAccess()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(fixture.writes == 2)
        #expect(fixture.launches == 1)
    }

    @Test("LEASE-01: Early timer wakes rearm against wall-clock changes rather than losing renewal")
    func earlyWakeRearmsUntilTheActualBoundary() async throws {
        let sleeper = LeaseSleeper()
        let fixture = try LeaseFixture(sleep: { try await sleeper.sleep($0) })
        defer { fixture.cleanup() }
        try await fixture.open()
        try await waitAsync { await sleeper.durations.contains(.seconds(86100)) }
        fixture.clock.advance(86099)
        await sleeper.resume(.seconds(86100))
        try await waitAsync { await sleeper.durations.contains(.seconds(1)) }
        #expect(fixture.auth.refreshCallCount == 0)
        #expect(fixture.writes == 1)
        fixture.clock.advance(1)
        await sleeper.resume(.seconds(1))
        try await wait { fixture.writes == 2 }
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(fixture.launches == 1)
    }

    @Test("LEASE-08: A backward wall-clock correction cannot shorten an existing lease")
    func rollbackPreservesDeadlineAndSchedulesAgain() async throws {
        let sleeper = LeaseSleeper()
        let fixture = try LeaseFixture(sleep: { try await sleeper.sleep($0) })
        defer { fixture.cleanup() }
        try await fixture.open()
        let before = try Data(contentsOf: fixture.leaseURL)
        fixture.clock.advance(-60)
        fixture.machine.renewAccess()
        await fixture.machine.awaitLeaseRenewal()
        #expect(try Data(contentsOf: fixture.leaseURL) == before)
        #expect(fixture.writes == 1)
        #expect(fixture.machine.leaseMessage?.contains("not shortened") == true)
        try await waitAsync { await sleeper.durations.contains(.seconds(86160)) }
    }

    @Test("LEASE-08: Renewal across declared key/lease-lifetime limits")
    func eachApprovedRollingLeaseIsFiniteAndRevalidated() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        for index in 1...3 {
            fixture.clock.advance(24 * 60 * 60 - 300)
            fixture.machine.checkLeaseContinuation()
            await fixture.machine.awaitLeaseRenewal()
            let renewed = try fixture.lease()
            #expect(renewed.expiresAt.timeIntervalSince(fixture.clock.date) == 24 * 60 * 60)
            #expect(renewed.generation == original.generation && renewed.keyPath == original.keyPath)
            #expect(fixture.auth.refreshCallCount == index)
            #expect(fixture.ec2.resolves == index + 1)
        }
        #expect(fixture.launches == 1 && fixture.recorder.values == ["key"])
    }

    @Test("LEASE-04: Renewal needs SSO, is offline, or access is denied",
          arguments: ["signin", "offline", "access", "expired-credentials"])
    func failuresKeepDeadlineAndAreExplicit(kind: String) async throws {
        let fixture = try LeaseFixture(sleep: { delay in
            if delay <= .seconds(60) { return }
            try await Task.sleep(for: delay)
        })
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try Data(contentsOf: fixture.leaseURL)
        switch kind {
        case "signin": fixture.auth.refreshOutcome = .failure(AuthError.signInRequired)
        case "offline": fixture.auth.refreshOutcome = .failure(URLError(.notConnectedToInternet))
        case "access": fixture.auth.refreshOutcome = .failure(AuthError.roleAccessDenied(accountId: "000000000000", roleName: "Example", detail: nil))
        default:
            fixture.auth.refreshOutcome = .success(AWSCredentials(accessKeyId: "fixture", secretAccessKey: "fixture",
                sessionToken: "fixture", expiration: fixture.clock.date))
        }
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(try Data(contentsOf: fixture.leaseURL) == original)
        #expect(fixture.machine.leaseMessage != nil)
        #expect(fixture.auth.refreshCallCount == (kind == "offline" ? 3 : 1))
        #expect(fixture.launches == 1 && fixture.writes == 1)
        #expect(fixture.machine.isActive && !fixture.machine.isRenewingLease)
        #expect(fixture.machine.leaseMessage?.contains("fixture") != true)
    }

    @Test("LEASE-04: A transient renewal failure retries only after the declared 30/60-second backoffs")
    func retryBackoffsAreBoundedAndVisible() async throws {
        let sleeper = LeaseSleeper()
        let fixture = try LeaseFixture(sleep: { try await sleeper.sleep($0) })
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.auth.refreshOutcome = .failure(URLError(.notConnectedToInternet))
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        try await wait { fixture.auth.refreshCallCount == 1 }
        try await waitAsync { await sleeper.durations.contains(.seconds(30)) }
        await sleeper.resume(.seconds(30))
        try await wait { fixture.auth.refreshCallCount == 2 }
        try await waitAsync { await sleeper.durations.contains(.seconds(60)) }
        await sleeper.resume(.seconds(60))
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.auth.refreshCallCount == 3 && fixture.writes == 1)
        #expect(fixture.machine.leaseMessage?.contains("failed after bounded attempts") == true)
    }

    @Test("LEASE-05: Stop, quit, profile/target/user change or revocation races renewal",
          arguments: ["stop", "quit", "profile", "owner", "generation", "instance", "user", "setup", "deadline", "key"])
    func changedContextNeverExtendsLeaseOrRecreatesAccess(change: String) async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.ec2.onResolve = {
            switch change {
            case "stop": fixture.machine.stop()
            case "quit": fixture.machine.terminateForQuit()
            case "profile":
                var changed = fixture.profile
                changed.roleName = "ChangedRole"
                fixture.machine.apply(profile: changed)
            case "owner": fixture.owner = (22222, Date(), "different-owner")
            case "generation":
                let changed = RemoteSSHLease(profile: original.profile, instanceID: original.instanceID, user: original.user,
                    keyPath: original.keyPath, pluginPath: original.pluginPath, ownerPID: original.ownerPID,
                    ownerLaunchDate: original.ownerLaunchDate, ownerBundleID: original.ownerBundleID,
                    generation: UUID(), expiresAt: original.expiresAt)
                try BrowserPrivateFiles.write(try JSONEncoder().encode(changed), to: fixture.leaseURL)
            case "instance": fixture.ec2.instance = .stub(id: "i-11111111111111111", state: .running)
            case "setup":
                try BrowserPrivateFiles.write(Data("Host unrelated\n  HostName example.invalid\n".utf8),
                    to: fixture.root.appendingPathComponent("user/config"))
            case "deadline": fixture.clock.advance(301)
            case "key": try FileManager.default.removeItem(atPath: original.keyPath)
            default:
                var changed = fixture.profile
                changed.webForwards?.sshUser = "different-user"
                fixture.machine.apply(profile: changed)
            }
        }
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.writes == 1 && fixture.launches == 1)
        if change == "stop" || change == "quit" { #expect(!FileManager.default.fileExists(atPath: fixture.leaseURL.path)) }
        else { #expect(try fixture.lease().expiresAt == original.expiresAt) }
    }

    @Test("LEASE-05 and LEASE-06: Disk replacement before renewal cannot become the owner's granted lease",
          arguments: ["generation", "key", "expiry"])
    func preAttemptReplacementIsRejectedBeforeAuthorization(change: String) async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        let keyPath: String
        if change == "key" {
            let alternative = fixture.root.appendingPathComponent("alternative/key")
            try BrowserPrivateFiles.write(Data("another-fixture-key".utf8), to: alternative)
            try BrowserPrivateFiles.write(Data("ssh-ed25519 another-fixture".utf8), to: URL(fileURLWithPath: alternative.path + ".pub"))
            keyPath = alternative.path
        } else { keyPath = original.keyPath }
        let replacement = RemoteSSHLease(profile: original.profile, instanceID: original.instanceID, user: original.user,
            keyPath: keyPath, pluginPath: original.pluginPath, ownerPID: original.ownerPID,
            ownerLaunchDate: original.ownerLaunchDate, ownerBundleID: original.ownerBundleID,
            generation: change == "generation" ? UUID() : original.generation,
            expiresAt: change == "expiry" ? original.expiresAt.addingTimeInterval(300) : original.expiresAt)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(replacement), to: fixture.leaseURL)
        let bytes = try Data(contentsOf: fixture.leaseURL)
        fixture.clock.advance(86100)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.auth.refreshCallCount == 0)
        #expect(fixture.writes == 1 && fixture.launches == 1)
        #expect(try Data(contentsOf: fixture.leaseURL) == bytes)
        #expect(fixture.machine.leaseMessage?.contains("not extended") == true)
    }

    @Test("LEASE-06: Renewal or atomic lease persistence fails")
    func failedPersistenceAndExpiredLeaseAreNotExtended() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try Data(contentsOf: fixture.leaseURL)
        fixture.writeError = CocoaError(.fileWriteNoPermission)
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(try Data(contentsOf: fixture.leaseURL) == original)
        #expect(fixture.machine.leaseMessage?.contains("not extended") == true)
        fixture.writeError = nil
        fixture.clock.advance(301)
        fixture.machine.renewAccess()
        await fixture.machine.awaitLeaseRenewal()
        #expect(try Data(contentsOf: fixture.leaseURL) == original)
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(fixture.launches == 1)
    }

    @Test("LEASE-04: Renew Editor Access retries after sign-in without a replacement editor window")
    func explicitRetryKeepsOriginalEditorAndKey() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        let success = fixture.auth.refreshOutcome
        fixture.auth.refreshOutcome = .failure(AuthError.signInRequired)
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.machine.leaseMessage?.contains("Sign In Required") == true)
        fixture.auth.refreshOutcome = success
        fixture.machine.renewAccess()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.machine.leaseMessage == nil)
        #expect(fixture.launches == 1)
        #expect(try fixture.lease().keyPath == original.keyPath)
        #expect(try fixture.lease().generation == original.generation)
        #expect(fixture.auth.authenticateCallCount == 1 && fixture.auth.refreshCallCount == 2)
    }

    @Test("LEASE-04: An unexpected AWS revocation is actionable without a renewal retry storm")
    func rejectedRunningInstanceAuthorizationRequiresSignIn() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.ec2.onResolve = {
            throw unmodeledAWSServiceError(typeName: "ExpiredTokenException", message: "fixture-revoked",
                                           statusCode: .unauthorized)
        }
        let original = try Data(contentsOf: fixture.leaseURL)
        fixture.clock.advance(24 * 60 * 60 - 300)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        #expect(fixture.machine.leaseMessage?.contains("Sign In Required") == true)
        #expect(fixture.machine.leaseMessage?.contains("fixture-revoked") != true)
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(try Data(contentsOf: fixture.leaseURL) == original)
    }

    @Test("LEASE-04: Renewal has a measured 60-second attempt budget and cannot retry beyond the deadline")
    func attemptTimeoutIsActuallyBounded() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.ec2.onResolve = {
            fixture.clock.advance(250)
            try await Task.sleep(for: .seconds(90))
        }
        fixture.clock.advance(24 * 60 * 60 - 300)
        let before = try Data(contentsOf: fixture.leaseURL)
        let started = ContinuousClock.now
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        let elapsed = ContinuousClock.now - started
        #expect(elapsed >= .seconds(59))
        #expect(elapsed < .seconds(65))
        #expect(fixture.auth.refreshCallCount == 1)
        #expect(try Data(contentsOf: fixture.leaseURL) == before)
        #expect(fixture.machine.leaseMessage?.contains("failed after bounded attempts") == true)
        #expect(!fixture.machine.isRenewingLease)
    }

    @Test("LEASE-01 and LEASE-05: A held owned channel survives its original deadline, then stops on revocation")
    func heldProcessSurvivesRenewalAndStillHonorsRevocation() async throws {
        let date = Date()
        let lease = RemoteSSHLease(profile: .example, instanceID: "i-0123456789abcdef0", user: "example",
            keyPath: "/fixture/key", pluginPath: "/fixture/plugin", ownerPID: 12345, ownerLaunchDate: date,
            ownerBundleID: "fixture-owner", generation: UUID(), expiresAt: date.addingTimeInterval(60))
        let monitor = LeaseMonitor(lease)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        process.arguments = ["-f", "/dev/null"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        let held = Task {
            try await RemoteSSHProxyRuntime.waitForOwnedProcess(process, isCurrent: monitor.isCurrent,
                pollInterval: .milliseconds(10), terminationGrace: .milliseconds(50))
        }
        monitor.renewed(lease.extending(until: date.addingTimeInterval(86400)))
        try await Task.sleep(for: .milliseconds(100))
        #expect(process.isRunning)
        monitor.revoke()
        _ = try await held.value
        #expect(!process.isRunning)
    }

    @Test("LEASE-03 and LEASE-05: The proxy observes a renewed deadline but rejects another key/generation/owner")
    func proxyUsesCurrentDeadlineWithoutRelaxingIdentity() throws {
        let date = Date()
        let original = RemoteSSHLease(profile: .example, instanceID: "i-0123456789abcdef0", user: "example",
            keyPath: "/fixture/key", pluginPath: "/fixture/plugin", ownerPID: 12345, ownerLaunchDate: date,
            ownerBundleID: "fixture-owner", generation: UUID(), expiresAt: date.addingTimeInterval(60))
        let later = date.addingTimeInterval(61)
        #expect(!original.continues(original, ownerActive: true, now: later))
        let renewed = original.extending(until: date.addingTimeInterval(86400))
        #expect(renewed.continues(original, ownerActive: true, now: later))
        #expect(!renewed.continues(original, ownerActive: false, now: later))
        let wrongKey = RemoteSSHLease(profile: original.profile, instanceID: original.instanceID, user: original.user,
            keyPath: "/different/key", pluginPath: original.pluginPath, ownerPID: original.ownerPID,
            ownerLaunchDate: original.ownerLaunchDate, ownerBundleID: original.ownerBundleID,
            generation: original.generation, expiresAt: renewed.expiresAt)
        #expect(!wrongKey.continues(original, ownerActive: true, now: later))
    }

    @Test("LEASE-03: Independent channels after the original deadline each refresh EIC authorization for the same identity")
    func freshProxyChannelsAuthorizeTheStableKeyAfterRollingExpiry() async throws {
        let fixture = try LeaseFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.clock.advance(86100)
        fixture.machine.checkLeaseContinuation()
        await fixture.machine.awaitLeaseRenewal()
        fixture.clock.advance(301)
        let renewed = try fixture.lease()
        try #require(renewed.continues(original, ownerActive: true, now: fixture.clock.date))
        try renewed.validate(path: fixture.leaseURL.path, ownerActive: true)
        let events = WebEventRecorder()
        let eic = FakeInstanceConnect(events)
        let ssm = MockSSMService()
        ssm.onStartSSHSession = { events.append("session") }
        let publicKey = try String(contentsOfFile: renewed.keyPath + ".pub", encoding: .utf8)
        for _ in 0..<2 {
            _ = try await RemoteSSHProxyRuntime.authorizeChannel(renewed, auth: fixture.auth, ec2: fixture.ec2,
                                                                 instanceConnect: eic, ssm: ssm)
            fixture.clock.advance(65)
        }
        #expect(eic.publicKeys == [publicKey, publicKey])
        #expect(eic.user == renewed.user)
        #expect(ssm.startSSHSessionCount == 2)
        #expect(events.values == ["push", "session", "push", "session"])
        #expect(fixture.auth.refreshCallCount == 3)
        #expect(renewed.generation == original.generation && renewed.keyPath == original.keyPath)
        #expect(fixture.launches == 1)
    }
}
