import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectHelperCore
@testable import SSMConnectWorkflow

/// The helper checks the exact plugin file before each launch, and real builds carry their build
/// ID where that check finds it (T22, AC-17).
@Suite("Installation check before launch")
struct InstallationCheckLaunchTests {
    /// A stand-in plugin: running it would create `ran` beside itself.
    static func plugin() throws -> (path: String, ran: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-launch-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ran = directory.appendingPathComponent("ran")
        #if os(Windows)
        let path = directory.appendingPathComponent("plugin.cmd")
        try Data("@echo ran > \"\(ran.path)\"\r\n".utf8).write(to: path)
        #else
        let path = directory.appendingPathComponent("plugin")
        try Data("#!/bin/sh\ntouch '\(ran.path)'\n".utf8).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path)
        #endif
        return (path.path, ran)
    }

    static let session = SSMSessionResponse(sessionId: "s", streamUrl: "wss://example.invalid", tokenValue: "t")

    @Test("The port-forward tunnel refuses a replaced plugin before starting it")
    func tunnelRefusesReplacedPlugin() async throws {
        let (path, ran) = try Self.plugin()
        let tunnel = ProcessTunnelProvider(pluginPath: { path }, verify: { _ in throw InstallationChange.updated })
        await #expect(throws: InstallationChange.updated) {
            _ = try await tunnel.startTunnel(session: Self.session, region: "eu-west-1", instanceId: "i-0",
                                             localPort: 48_123, remotePort: 8443)
        }
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    @Test("Web forwards refuse a removed plugin before starting SSH")
    func webForwardsRefuseRemovedPlugin() async throws {
        let (path, ran) = try Self.plugin()
        let tunnel = ProcessSSHTunnel(sshPath: { path }, pluginPath: { path }, style: .posix,
                                      verify: { _ in throw InstallationChange.removed })
        var configuration = WebForwardsConfiguration()
        configuration.socksPort = 48_124
        await #expect(throws: InstallationChange.removed) {
            _ = try await tunnel.start(session: Self.session, region: "eu-west-1", instanceId: "i-0", user: "ec2-user",
                                       keyPath: "/tmp/key", configuration: configuration)
        }
        #expect(!FileManager.default.fileExists(atPath: ran.path))
    }

    @Test("The built helper carries its build ID where the check looks for it")
    func helperCarriesItsBuild() throws {
        try InstallationCheck(build: InstalledBuild.current, pluginSHA256: nil).executable(at: ProtocolTests.helperExecutable.path)
        #expect(throws: InstallationChange.updated) {
            try InstallationCheck(build: InstalledBuild.current + "-other", pluginSHA256: nil)
                .executable(at: ProtocolTests.helperExecutable.path)
        }
    }
}
