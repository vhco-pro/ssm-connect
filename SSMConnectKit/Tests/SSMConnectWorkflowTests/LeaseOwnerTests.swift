import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// Editor leases record their owner's build, and their owner is identified through a port: the
/// app on macOS, the helper's PID and start time on Windows and Linux (T16, AC-17).
@Suite("Lease owner and build")
struct LeaseOwnerTests {
    static func lease(build: String?) -> RemoteSSHLease {
        var profile = ConnectionProfile(name: "Workstation", ssoStartUrl: "https://d-0123456789.awsapps.com/start",
                                        ssoRegion: "eu-west-1", accountId: "111122223333", roleName: "Admin",
                                        resourceRegion: "eu-central-1", instanceTagKey: "Name", instanceTagValue: "ws",
                                        localPort: 8443, remotePort: 8443)
        profile.id = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        return RemoteSSHLease(profile: profile, instanceID: "i-0123456789abcdef0", user: "ec2-user",
                              keyPath: "/tmp/key", pluginPath: "/tmp/plugin", ownerPID: 4242,
                              ownerLaunchDate: Date(timeIntervalSince1970: 1_800_000_000), ownerBundleID: "owner",
                              generation: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
                              expiresAt: Date(timeIntervalSince1970: 1_800_086_400), ownerBuild: build)
    }

    @Test("A proxy of the owner's build admits the channel")
    func sameBuild() throws {
        try Self.lease(build: InstalledBuild.current).requireSameBuild()
        try Self.lease(build: "2.0.0").requireSameBuild("2.0.0")
    }

    @Test("A proxy of another build, or a lease from before builds were recorded, refuses with the restart message")
    func otherBuild() {
        #expect(throws: RemoteSSHError.updated) { try Self.lease(build: "1.0.0").requireSameBuild("2.0.0") }
        #expect(throws: RemoteSSHError.updated) { try Self.lease(build: nil).requireSameBuild("2.0.0") }
        #expect(RemoteSSHError.updated.errorDescription == "SSM Connect was updated; restart it.")
    }

    @Test("A lease written before builds were recorded still decodes, and writes no build key")
    func compatibility() throws {
        let old = try JSONEncoder().encode(Self.lease(build: nil))
        let object = try JSONSerialization.jsonObject(with: old) as? [String: Any]
        #expect(object?["ownerBuild"] == nil)
        #expect(try JSONDecoder().decode(RemoteSSHLease.self, from: old).ownerBuild == nil)
        let stamped = Self.lease(build: "2.0.0")
        #expect(try JSONDecoder().decode(RemoteSSHLease.self, from: JSONEncoder().encode(stamped)) == stamped)
    }

    @Test("Renewal keeps the build, and a lease of another build does not continue the original")
    func continuation() {
        let original = Self.lease(build: "2.0.0")
        let renewed = original.extending(until: original.expiresAt.addingTimeInterval(3600))
        #expect(renewed.ownerBuild == "2.0.0")
        #expect(renewed.continues(original, ownerActive: true, now: original.expiresAt.addingTimeInterval(-60)))
        let rebuilt = RemoteSSHLease(profile: original.profile, instanceID: original.instanceID, user: original.user,
                                     keyPath: original.keyPath, pluginPath: original.pluginPath, ownerPID: original.ownerPID,
                                     ownerLaunchDate: original.ownerLaunchDate, ownerBundleID: original.ownerBundleID,
                                     generation: original.generation, expiresAt: original.expiresAt, ownerBuild: "3.0.0")
        #expect(!rebuilt.continues(original, ownerActive: true, now: original.expiresAt.addingTimeInterval(-60)))
        #expect(original.owner == LeaseOwnerIdentity(pid: 4242, launchDate: original.ownerLaunchDate, bundleID: "owner"))
    }

    #if os(Linux) || os(Windows)
    @Test("The helper owner is its PID and start time, and a finished or reused PID is not active")
    func processOwner() throws {
        let owner = ProcessLeaseOwner()
        let current = try #require(owner.current())
        #expect(current.bundleID == ProcessLeaseOwner.bundleID && owner.isActive(current))
        #expect(!owner.isActive(LeaseOwnerIdentity(pid: current.pid, launchDate: current.launchDate.addingTimeInterval(1),
                                                    bundleID: current.bundleID)))
        #expect(!owner.isActive(LeaseOwnerIdentity(pid: current.pid, launchDate: current.launchDate, bundleID: "other")))

        let child = Process()
        #if os(Windows)
        child.executableURL = URL(fileURLWithPath: "C:\\Windows\\System32\\cmd.exe")
        child.arguments = ["/c", "exit", "0"]
        #else
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "sleep 0.3"]
        #endif
        try child.run()
        let started = ProcessLeaseOwner.startTime(of: child.processIdentifier)
        child.waitUntilExit()
        if let started {
            #expect(!owner.isActive(LeaseOwnerIdentity(pid: child.processIdentifier, launchDate: started,
                                                        bundleID: ProcessLeaseOwner.bundleID)))
        }
    }
    #endif
}
