import Carbon
import Foundation
import Testing
@testable import SSMConnectKit

private actor KeyGenerationGate {
    private(set) var entered = false
    private var released = false
    func release() { released = true }
    func wait() async throws {
        entered = true
        while !released { try await Task.sleep(for: .milliseconds(10)) }
    }
}

private struct GatedRecoveryKeyGenerator: SSHKeyGenerating {
    let base: LeaseKeyGenerator
    let gate: KeyGenerationGate
    func generate() async throws -> SSHKeyMaterial {
        try await gate.wait()
        return try await base.generate()
    }
}

@MainActor
private final class WorkspaceRecoveryFixture {
    let root: URL
    let clock = LeaseClock()
    let store = InMemoryKeyValueStore()
    let auth = MockAuthProvider()
    let ec2 = LeaseEC2()
    let ssm = MockSSMService()
    let recorder = WebEventRecorder()
    var profile = ConnectionProfile.example
    var owner = (pid: Int32(12000), launchDate: Date(), bundleID: "workspace-fixture")
    var machine: RemoteDevelopmentStateMachine!
    var launches = 0
    var sleeps: [Duration] = []
    var holdWait = false
    var budget: Duration = .seconds(30 * 60)
    var existingOwnerIsActive = false
    var authorizationCalls: Int { auth.authenticateCallCount + auth.refreshCallCount }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-workspace-fixture-" + UUID().uuidString)
        try BrowserPrivateFiles.directory(root)
        profile.remoteDevelopment = .init(enabled: true, folder: "/home/example/project")
        profile.webForwards = .init(sshUser: "example")
        let credentials = AWSCredentials(accessKeyId: "fixture", secretAccessKey: "fixture", sessionToken: "fixture",
                                         expiration: clock.date.addingTimeInterval(10 * 24 * 60 * 60))
        auth.authenticateOutcome = .success(credentials)
        auth.refreshOutcome = .success(credentials)
        machine = makeMachine()
        try machine.installSetup(consent: true)
    }

    var leaseURL: URL { root.appendingPathComponent("access/\(profile.id.uuidString)/lease.json") }
    func lease() throws -> RemoteSSHLease { try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL)) }

    func makeMachine(keyGenerator: (any SSHKeyGenerating)? = nil) -> RemoteDevelopmentStateMachine {
        RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("access"),
            configURL: root.appendingPathComponent("user/config"), auth: auth, ec2: ec2, ssm: ssm,
            keyGenerator: keyGenerator ?? LeaseKeyGenerator(root: root.appendingPathComponent("keys"), recorder: recorder),
            helperPath: { "/usr/bin/true" }, pluginPath: { "/usr/bin/true" },
            editorPath: { "/usr/bin/true" }, editorPreflight: { _ in },
            ownerIdentity: { [weak self] in self?.owner }, now: { [clock] in clock.date },
            launchEditor: { [weak self] _, _ in self?.launches += 1 }, resumeStore: store,
            recoverySleep: { [weak self] duration in
                guard let self else { throw CancellationError() }
                try await self.wait(duration)
            }, recoveryBudget: budget, leaseOwnerIsActive: { [weak self] _ in self?.existingOwnerIsActive == true })
    }

    func wait(_ duration: Duration) async throws {
        sleeps.append(duration)
        if holdWait { try await Task.sleep(for: .seconds(60)) }
        else { clock.advance(15); await Task.yield() }
    }

    func open() async throws {
        machine.open()
        await machine.awaitOpening()
        try #require(machine.errorMessage == nil)
        try #require(machine.isActive)
    }

    func restart() {
        machine.terminateForQuit()
        owner.pid += 1
        owner.launchDate = owner.launchDate.addingTimeInterval(1)
        machine = makeMachine()
    }

    func cleanup() {
        machine.terminateForQuit()
        do { try FileManager.default.removeItem(at: root) }
        catch { Issue.record("Could not remove the owned recovery fixture: \(error.localizedDescription)") }
    }
}

@Suite("Original editor workspace recovery")
@MainActor
struct EditorWorkspaceRecoveryTests {
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        try #require(condition())
    }

    @Test("UPGRADE-01 and UPGRADE-03: Explicit relaunch prepares fresh access for the original authority without another window")
    func explicitLaunchRestoresOnlyTheSameWorkspace() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.restart()
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        let restored = try fixture.lease()
        #expect(fixture.machine.errorMessage == nil && fixture.machine.isActive)
        #expect(restored.profile.id == original.profile.id && restored.instanceID == original.instanceID)
        #expect(restored.user == original.user)
        #expect(restored.ownerPID != original.ownerPID && restored.generation != original.generation)
        #expect(restored.keyPath != original.keyPath)
        #expect(fixture.launches == 1 && !fixture.machine.editorLaunched)
        #expect(fixture.ec2.starts == 0)
        #expect(fixture.machine.recoveryMessage?.contains("Access prepared for the same workspace") == true)
        let config = try String(contentsOf: fixture.root.appendingPathComponent("access/hosts/config"), encoding: .utf8)
        #expect(config.contains("Host " + RemoteSSHConfiguration.alias(original.profile.id)))
    }

    @Test("UPGRADE-05: Stop, disabled configuration, unknown launch or missing legacy intent never opts into access",
          arguments: ["stop", "disabled", "background", "legacy", "changed-role"])
    func cancelledAndUnapprovedRecoveryNeverStartsAWS(reason: String) async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        if reason != "legacy" { try await fixture.open() }
        if reason == "stop" { fixture.machine.stop() }
        if reason == "disabled" { fixture.profile.remoteDevelopment?.enabled = false }
        if reason == "changed-role" { fixture.profile.roleName = "DifferentRole" }
        let count = fixture.authorizationCalls
        fixture.restart()
        fixture.machine.onLaunch(explicit: reason != "background")
        await fixture.machine.awaitOpening()
        #expect(fixture.authorizationCalls == count)
        #expect(!fixture.machine.isActive)
        #expect(fixture.ec2.starts == 0)
    }

    @Test("UPGRADE-05: Only known explicit application-open events trigger automatic restoration")
    func loginAndUnknownAppleEventsDoNotBecomeLaunchConsent() {
        #expect(AppLaunchHandler.isExplicit(eventID: AEEventID(kAEOpenApplication), loginFlag: false, propertyData: nil))
        #expect(!AppLaunchHandler.isExplicit(eventID: nil, loginFlag: false, propertyData: nil))
        #expect(!AppLaunchHandler.isExplicit(eventID: AEEventID(kAEOpenApplication), loginFlag: true, propertyData: nil))
        #expect(!AppLaunchHandler.isExplicit(eventID: AEEventID(kAEOpenApplication), loginFlag: false,
                                           propertyData: OSType(keyAELaunchedAsLogInItem)))
    }

    @Test("REBUILD-01 and REBUILD-06: A replacement requires one review and fresh binding, not another Recent identity")
    func replacementConfirmationPreservesAuthorityAndRotatesPhysicalGrant() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.ec2.instance = .stub(id: "i-11111111111111111", state: .running)
        fixture.machine.reconnectExistingWorkspace()
        await fixture.machine.awaitOpening()
        let candidate = try #require(fixture.machine.pendingReplacement)
        #expect(candidate.previousInstanceID == original.instanceID)
        #expect(try fixture.lease() == original)
        #expect(fixture.recorder.values == ["key"])
        fixture.machine.approveReplacement(candidate.id)
        await fixture.machine.awaitOpening()
        let rebound = try fixture.lease()
        #expect(fixture.machine.errorMessage == nil)
        #expect(rebound.instanceID == candidate.instanceID && rebound.user == original.user)
        #expect(rebound.profile.id == original.profile.id)
        #expect(rebound.generation != original.generation && rebound.keyPath != original.keyPath)
        #expect(fixture.launches == 1 && fixture.ec2.starts == 0)
        #expect(fixture.machine.pendingReplacement == nil)
        let config = try String(contentsOf: fixture.root.appendingPathComponent("access/hosts/config"), encoding: .utf8)
        #expect(config.contains("HostKeyAlias " + candidate.instanceID))
        #expect(config.contains("StrictHostKeyChecking accept-new"))
        #expect(!config.contains("StrictHostKeyChecking no"))
        fixture.restart()
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.pendingReplacement == nil)
        #expect(try fixture.lease().instanceID == candidate.instanceID)
        #expect(fixture.launches == 1)
    }

    @Test("REBUILD-06: Approval is invalidated when the resolved replacement or profile changes",
          arguments: [false, true])
    func staleReplacementApprovalCannotAuthorizeAnotherTarget(changeProfile: Bool) async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.ec2.instance = .stub(id: "i-11111111111111111", state: .running)
        fixture.machine.reconnectExistingWorkspace()
        await fixture.machine.awaitOpening()
        let candidate = try #require(fixture.machine.pendingReplacement)
        if changeProfile {
            var changed = fixture.profile
            changed.roleName = "OtherRole"
            fixture.machine.apply(profile: changed)
        } else { fixture.ec2.instance = .stub(id: "i-22222222222222222", state: .running) }
        fixture.machine.approveReplacement(candidate.id)
        await fixture.machine.awaitOpening()
        #expect(try fixture.lease() == original)
        #expect(fixture.recorder.values == ["key"])
        if !changeProfile { #expect(fixture.machine.pendingReplacement?.instanceID == "i-22222222222222222") }
    }

    @Test("REBUILD-09: Missing/pending workstation recovery is cancellable and never starts EC2")
    func waitsForExternalReadinessThenReusesTheSavedWorkspace() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.restart()
        let initialCount = fixture.ec2.resolves
        fixture.ec2.onResolve = {
            if fixture.ec2.resolves <= initialCount + 3 {
                throw EC2Error.noMatchingInstance(tagKey: "Name", tagValue: "synthetic")
            }
        }
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage == nil && fixture.machine.isActive)
        #expect(fixture.sleeps == [.seconds(15), .seconds(15), .seconds(15)])
        #expect(fixture.ec2.starts == 0 && fixture.launches == 1)
    }

    @Test("REBUILD-09 and UPGRADE-05: Cancel and Stop cannot recreate access during a readiness wait",
          arguments: [false, true])
    func waitCancellationDoesNotRecreateAccess(stop: Bool) async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.restart()
        fixture.ec2.instance = .stub(state: .stopped)
        fixture.holdWait = true
        fixture.machine.onLaunch(explicit: true)
        try await wait { !fixture.sleeps.isEmpty }
        if stop { fixture.machine.stop() } else { fixture.machine.cancelRecovery() }
        await Task.yield()
        #expect(!fixture.machine.isActive && !fixture.machine.isRecovering)
        #expect(fixture.ec2.starts == 0)
        if stop {
            fixture.restart()
            fixture.machine.onLaunch(explicit: true)
            await fixture.machine.awaitOpening()
            #expect(!fixture.machine.isActive)
        }
    }

    @Test("REBUILD-09: The overall readiness wait has a finite cancellation deadline")
    func recoveryBudgetIsEnforced() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.budget = .milliseconds(80)
        fixture.restart()
        fixture.holdWait = true
        fixture.ec2.instance = .stub(state: .stopped)
        let started = ContinuousClock.now
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(fixture.machine.errorMessage == StageTimeoutError(stage: "Existing workspace recovery").localizedDescription)
        #expect(!fixture.machine.isActive && fixture.ec2.starts == 0)
    }

    @Test("REBUILD-06: Ambiguous targets and denied authorization are terminal, not rebuild retries",
          arguments: [false, true])
    func ambiguousAndDeniedStatesDoNotRetry(accessDenied: Bool) async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.restart()
        if accessDenied {
            fixture.auth.refreshOutcome = .failure(AuthError.roleAccessDenied(accountId: "000000000000",
                                                                             roleName: "Example", detail: nil))
        } else {
            fixture.ec2.onResolve = { throw EC2Error.multipleMatchingInstances(tagKey: "Name", tagValue: "synthetic", count: 2) }
        }
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage != nil)
        #expect(fixture.sleeps.isEmpty && !fixture.machine.isActive)
    }

    @Test("UPGRADE-06: Invalid remembered metadata is visible and cannot trigger AWS")
    func corruptIntentDoesNotBecomeAutomaticAccess() throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        fixture.store.set(Data("invalid-json".utf8), forKey: "ssmconnect.editorRecovery.v1")
        fixture.machine.onLaunch(explicit: true)
        #expect(fixture.authorizationCalls == 0)
        #expect(fixture.machine.errorMessage == RemoteSSHError.invalidRecoveryState.localizedDescription)
    }

    @Test("REBUILD-08: A lease-bound proxy request reaches owner review without modifying SSH configuration")
    func proxyRequestCoalescesAndUsesTheOwnedContext() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        let request = EditorRecoveryRequest(lease: original, reason: .targetChanged)
        try request.write(for: fixture.leaseURL)
        fixture.ec2.instance = .stub(id: "i-11111111111111111", state: .running)
        fixture.machine.processRecoveryRequests()
        fixture.machine.processRecoveryRequests()
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.pendingReplacement?.previousInstanceID == original.instanceID)
        #expect(try fixture.lease() == original)
        let count = fixture.authorizationCalls
        fixture.machine.processRecoveryRequests()
        await fixture.machine.awaitOpening()
        #expect(fixture.authorizationCalls == count)
        #expect(fixture.launches == 1)
    }

    @Test("UPGRADE-05: A stopped profile cannot be revived by a stale helper request")
    func stoppedAccessIgnoresLaterRecoveryRequests() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.machine.stop()
        let count = fixture.authorizationCalls
        try EditorRecoveryRequest(lease: original, reason: .expired).write(for: fixture.leaseURL)
        fixture.machine.processRecoveryRequests()
        await fixture.machine.awaitOpening()
        #expect(fixture.authorizationCalls == count)
        #expect(!fixture.machine.isActive)
        #expect(try EditorRecoveryStore(store: fixture.store).intent(for: fixture.profile.id) == nil)
    }

    @Test("UPGRADE-04: Recovery requires a silent credential refresh; expired SSO never opens another sign-in flow")
    func signInIsAnExplicitUserAction() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.restart()
        let original = fixture.auth.authenticateCallCount
        fixture.auth.refreshOutcome = .failure(AuthError.signInRequired)
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.auth.authenticateCallCount == original)
        #expect(fixture.machine.errorMessage == AuthError.signInRequired.localizedDescription)
        #expect(!fixture.machine.isActive && fixture.launches == 1)
    }

    @Test("REBUILD-08: Another live owner's lease is never replaced, even if it has expired")
    func liveOwnerConflictIsNotARebind() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.restart()
        let expired = original.extending(until: fixture.clock.date.addingTimeInterval(-1))
        try BrowserPrivateFiles.write(try JSONEncoder().encode(expired), to: fixture.leaseURL)
        fixture.existingOwnerIsActive = true
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage == RemoteSSHError.configurationConflict.localizedDescription)
        #expect(try fixture.lease() == expired)
        #expect(fixture.recorder.values == ["key"] && !fixture.machine.isActive)
    }

    @Test("REBUILD-08: Requests from an older generation cannot cause AWS recovery")
    func oldGenerationCannotTriggerRecovery() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        let stale = EditorRecoveryRequest(lease: original, reason: .expired)
        fixture.restart()
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        let count = fixture.authorizationCalls
        try stale.write(for: fixture.leaseURL)
        fixture.machine.processRecoveryRequests()
        await fixture.machine.awaitOpening()
        #expect(fixture.authorizationCalls == count)
        #expect(fixture.machine.errorMessage == nil)
        #expect(fixture.machine.recoveryMessage?.contains("earlier recovery notice was ignored") == true)
    }

    @Test("UPGRADE-05: Restore Editor Setup clears every remembered resume intent")
    func restoreSetupClearsIntent() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        try fixture.machine.restoreSetup()
        #expect(try EditorRecoveryStore(store: fixture.store).intent(for: fixture.profile.id) == nil)
        #expect(!fixture.machine.setupInstalled && !fixture.machine.isActive)
    }

    @Test("REBUILD-09: SSM not-online is a readiness wait, not an immediate terminal failure")
    func ssmNotOnlineCanBeRetriedWithinBudget() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        fixture.restart()
        fixture.ssm.waitError = SSMError.notOnlineInTime(instanceId: "i-0123456789abcdef0")
        fixture.ec2.onResolve = {
            if !fixture.sleeps.isEmpty { fixture.ssm.waitError = nil }
        }
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.isActive && fixture.machine.errorMessage == nil)
        #expect(fixture.sleeps == [.seconds(15)] && fixture.ec2.starts == 0)
    }

    @Test("REBUILD-06: A different resolved user never inherits the remembered workspace grant")
    func userMismatchCannotBecomeNewAccess() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        fixture.restart()
        try EditorRecoveryStore(store: fixture.store).remember(EditorRecoveryIntent(
            profile: fixture.profile, instanceID: original.instanceID, user: "another-user"))
        fixture.machine.onLaunch(explicit: true)
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage == RemoteSSHError.targetChanged.localizedDescription)
        #expect(!fixture.machine.isActive && fixture.recorder.values == ["key"])
    }

    @Test("REBUILD-08: Invalid or non-private helper messages cannot authorize recovery",
          arguments: ["malformed", "public", "oversized"])
    func invalidHelperMessageCannotTriggerAWS(kind: String) async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let lease = try fixture.lease()
        let url = EditorRecoveryRequest.url(for: fixture.leaseURL)
        try EditorRecoveryRequest(lease: lease, reason: .expired).write(for: fixture.leaseURL)
        if kind == "public" {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        } else {
            try BrowserPrivateFiles.write(Data(repeating: 0x61, count: kind == "oversized" ? 4096 : 10), to: url)
        }
        let count = fixture.authorizationCalls
        fixture.machine.processRecoveryRequests()
        await fixture.machine.awaitOpening()
        #expect(fixture.authorizationCalls == count && fixture.machine.errorMessage != nil)
        #expect(try fixture.lease() == lease)
    }

    @Test("UPGRADE-05: Stop cannot delete an independently replaced owner's lease")
    func stopLeavesUnknownGrantUntouched() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        try await fixture.open()
        let original = try fixture.lease()
        let other = RemoteSSHLease(profile: original.profile, instanceID: original.instanceID,
            user: original.user, keyPath: original.keyPath, pluginPath: original.pluginPath,
            ownerPID: original.ownerPID + 100, ownerLaunchDate: original.ownerLaunchDate,
            ownerBundleID: original.ownerBundleID, generation: UUID(), expiresAt: original.expiresAt)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(other), to: fixture.leaseURL)
        fixture.machine.stop()
        #expect(!fixture.machine.isActive)
        #expect(try fixture.lease() == other)
        #expect(fixture.machine.errorMessage == RemoteSSHError.configurationConflict.localizedDescription)
    }

    @Test("UPGRADE-05 and REBUILD-08: A delayed publisher cannot overwrite a competing owner's new grant")
    func latePublisherCannotOverwriteAnotherOwner() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        let gate = KeyGenerationGate()
        fixture.machine = fixture.makeMachine(keyGenerator: GatedRecoveryKeyGenerator(
            base: LeaseKeyGenerator(root: fixture.root.appendingPathComponent("delayed-keys"), recorder: fixture.recorder),
            gate: gate))
        let winner = fixture.makeMachine()
        defer { fixture.machine.terminateForQuit(); winner.terminateForQuit(); fixture.cleanup() }
        fixture.machine.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await gate.entered), ContinuousClock.now < deadline { await Task.yield() }
        try #require(await gate.entered)
        winner.open()
        await winner.awaitOpening()
        try #require(winner.isActive && winner.errorMessage == nil)
        let winningLease = try fixture.lease()
        let hostURL = fixture.root.appendingPathComponent("access/hosts/config")
        let winningConfig = try Data(contentsOf: hostURL)
        await gate.release()
        await fixture.machine.awaitOpening()
        #expect(!fixture.machine.isActive)
        #expect(fixture.machine.errorMessage == RemoteSSHError.configurationConflict.localizedDescription)
        #expect(try fixture.lease() == winningLease)
        #expect(try Data(contentsOf: hostURL) == winningConfig)
        #expect(winner.isActive)
    }

    @Test("UPGRADE-05 and REBUILD-08: A separate process holding the publication lock prevents any new grant")
    func separateProcessPublicationLockIsExclusive() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        let executable = fixture.root.appendingPathComponent("publication-lock-holder")
        let diagnostics = fixture.root.appendingPathComponent("compiler-output")
        try BrowserPrivateFiles.write(Data(), to: diagnostics)
        let output = try FileHandle(forWritingTo: diagnostics)
        defer { try? output.close() }
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = ["clang", "-x", "c", "-", "-o", executable.path]
        let source = Pipe()
        compiler.standardInput = source
        compiler.standardOutput = output
        compiler.standardError = output
        let program = """
        #include <fcntl.h>
        #include <unistd.h>
        int main(int argc, char **argv) {
            if (argc != 3) return 1;
            int fd = open(argv[1], O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
            if (fd < 0) return 2;
            struct flock lock = {0};
            lock.l_type = F_WRLCK;
            lock.l_whence = SEEK_SET;
            if (fcntl(fd, F_SETLK, &lock) != 0) return 3;
            int ready = open(argv[2], O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (ready < 0 || write(ready, "1", 1) != 1) return 4;
            close(ready);
            char release;
            if (read(STDIN_FILENO, &release, 1) < 0) return 5;
            close(fd);
            return 0;
        }
        """
        try compiler.run()
        defer { if compiler.isRunning { compiler.terminate() } }
        try source.fileHandleForWriting.write(contentsOf: Data(program.utf8))
        try source.fileHandleForWriting.close()
        let compileDeadline = ContinuousClock.now.advanced(by: .seconds(20))
        while compiler.isRunning, ContinuousClock.now < compileDeadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!compiler.isRunning, "The owned publication-lock fixture did not compile within its budget.")
        let compilerMessage = try String(contentsOf: diagnostics, encoding: .utf8)
        try #require(compiler.terminationStatus == 0, "Could not compile the owned lock fixture: \(compilerMessage)")

        let holder = Process()
        let release = Pipe()
        let ready = fixture.root.appendingPathComponent("publication-lock-ready")
        holder.executableURL = executable
        holder.arguments = [fixture.root.appendingPathComponent("access/.editor-publication.lock").path, ready.path]
        holder.standardInput = release
        holder.standardOutput = FileHandle.nullDevice
        holder.standardError = FileHandle.nullDevice
        try holder.run()
        defer {
            try? release.fileHandleForWriting.close()
            if holder.isRunning { holder.terminate() }
        }
        try await wait { FileManager.default.fileExists(atPath: ready.path) || !holder.isRunning }
        try #require(holder.isRunning && FileManager.default.fileExists(atPath: ready.path))
        let host = fixture.root.appendingPathComponent("access/hosts/config")
        let originalHost = try Data(contentsOf: host)
        fixture.machine.open()
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage == RemoteSSHError.configurationConflict.localizedDescription)
        #expect(!fixture.machine.isActive && holder.isRunning)
        #expect(!FileManager.default.fileExists(atPath: fixture.leaseURL.path))
        #expect(try Data(contentsOf: host) == originalHost)

        try release.fileHandleForWriting.close()
        try await wait { !holder.isRunning }
        #expect(holder.terminationStatus == 0)
        try await fixture.open()
        #expect(fixture.launches == 1)
    }

    @Test("UPGRADE-06: Ordinary editor cold starts retain their 120-second SSM readiness window")
    func explicitEditorColdStartWaitsPastRecoverySlice() async throws {
        let fixture = try WorkspaceRecoveryFixture()
        defer { fixture.cleanup() }
        fixture.ec2.instance = .stub(state: .stopped)
        fixture.ssm.onWaitForSSMOnline = { timeout in
            #expect(timeout == .seconds(120))
            try await Task.sleep(for: .seconds(35))
        }
        let started = ContinuousClock.now
        fixture.machine.open()
        await fixture.machine.awaitOpening()
        #expect(fixture.machine.errorMessage == nil && fixture.machine.isActive)
        #expect(ContinuousClock.now - started >= .seconds(35))
        #expect(fixture.ec2.starts == 1)
    }
}
