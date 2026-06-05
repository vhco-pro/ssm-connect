import Foundation
import Testing
@testable import SSMConnect

/// Unit tests for `BundledPluginTunnel` provider + handle lifecycle (D9).
@Suite("BundledPluginTunnel")
struct BundledPluginTunnelTests {
    private let session = SSMSessionResponse.stub()

    // MARK: - Availability (D7)

    @Test("checkAvailability reports missing when the plugin path does not exist")
    func availabilityMissing() {
        let tunnel = BundledPluginTunnel(pluginPath: { "/nonexistent/session-manager-plugin" })
        #expect(tunnel.checkAvailability() == .pluginMissing(path: "/nonexistent/session-manager-plugin"))
    }

    @Test("checkAvailability reports not-executable for a non-exec file")
    func availabilityNotExecutable() throws {
        let path = try TempFile.make(executable: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tunnel = BundledPluginTunnel(pluginPath: { path })
        #expect(tunnel.checkAvailability() == .pluginNotExecutable(path: path))
    }

    @Test("checkAvailability reports available for an executable file")
    func availabilityAvailable() throws {
        let path = try TempFile.make(executable: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tunnel = BundledPluginTunnel(pluginPath: { path })
        #expect(tunnel.checkAvailability() == .available)
    }

    // MARK: - Argument construction (spec §6.4)

    @Test("pluginArguments builds the 5-arg invocation contract")
    func argumentsContract() throws {
        let args = try BundledPluginTunnel.pluginArguments(
            session: session, region: "eu-central-1", instanceId: "i-abc",
            localPort: 8443, remotePort: 8443
        )
        #expect(args.count == 5)
        #expect(args[1] == "eu-central-1")
        #expect(args[2] == "StartSession")
        #expect(args[3] == "")

        // arg[0] is the session JSON
        let sessionObj = try JSONSerialization.jsonObject(with: Data(args[0].utf8)) as? [String: Any]
        #expect(sessionObj?["SessionId"] as? String == session.sessionId)
        #expect(sessionObj?["StreamUrl"] as? String == session.streamUrl)
        #expect(sessionObj?["TokenValue"] as? String == session.tokenValue)

        // arg[4] is the parameters JSON
        let paramObj = try JSONSerialization.jsonObject(with: Data(args[4].utf8)) as? [String: Any]
        #expect(paramObj?["Target"] as? String == "i-abc")
        #expect(paramObj?["DocumentName"] as? String == "AWS-StartPortForwardingSession")
        let params = paramObj?["Parameters"] as? [String: [String]]
        #expect(params?["portNumber"] == ["8443"])
        #expect(params?["localPortNumber"] == ["8443"])
    }

    // MARK: - startTunnel guards

    @Test("startTunnel throws pluginMissing when the binary is absent")
    func startThrowsPluginMissing() async {
        let tunnel = BundledPluginTunnel(pluginPath: { "/nonexistent/session-manager-plugin" })
        await #expect(throws: TunnelError.pluginMissing(path: "/nonexistent/session-manager-plugin")) {
            _ = try await tunnel.startTunnel(session: session, region: "eu-central-1", instanceId: "i-abc", localPort: 8443, remotePort: 8443)
        }
    }

    @Test("startTunnel throws localPortInUse when the port is occupied")
    func startThrowsPortInUse() async throws {
        let path = try TempFile.make(executable: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let tunnel = BundledPluginTunnel(
            pluginPath: { path },
            spawner: FakePluginSpawner(),
            portProbe: StubPortProbe(occupantToReturn: PortOccupant(pid: 999, processName: "ssh"))
        )
        await #expect(throws: TunnelError.localPortInUse(port: 8443, pid: 999, processName: "ssh")) {
            _ = try await tunnel.startTunnel(session: session, region: "eu-central-1", instanceId: "i-abc", localPort: 8443, remotePort: 8443)
        }
    }

    @Test("startTunnel spawns the plugin and returns an active handle")
    func startSucceeds() async throws {
        let path = try TempFile.make(executable: true)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let spawner = FakePluginSpawner(process: FakePluginProcess(pid: 5555))
        let tunnel = BundledPluginTunnel(
            pluginPath: { path },
            spawner: spawner,
            portProbe: StubPortProbe(occupantToReturn: nil)
        )

        let handle = try await tunnel.startTunnel(
            session: session, region: "eu-central-1", instanceId: "i-abc",
            localPort: 8443, remotePort: 8443
        )

        #expect(spawner.spawnCount == 1)
        #expect(spawner.lastExecutablePath == path)
        #expect(spawner.lastArguments?.count == 5)
        #expect(handle.isActive)
        #expect(handle.processIdentifier == 5555)
    }

    // MARK: - Handle lifecycle (D5, F-13)

    @Test("terminate sends SIGTERM and emits terminatedByUser")
    func terminateGraceful() async throws {
        let process = FakePluginProcess()
        try process.start()
        let handle = BundledPluginTunnelHandle(process: process, gracePeriod: .milliseconds(50), pollInterval: .milliseconds(1))

        await handle.terminate()

        #expect(process.sigtermCount == 1)
        #expect(process.sigkillCount == 0)
        #expect(!handle.isActive)

        var reasons: [TunnelDropReason] = []
        for await reason in handle.onDisconnect { reasons.append(reason) }
        #expect(reasons == [.terminatedByUser])
    }

    @Test("terminate escalates to SIGKILL when SIGTERM is ignored")
    func terminateForceKill() async throws {
        let process = FakePluginProcess()
        process.respondsToSIGTERM = false
        try process.start()
        let handle = BundledPluginTunnelHandle(process: process, gracePeriod: .milliseconds(20), pollInterval: .milliseconds(1))

        await handle.terminate()

        #expect(process.sigtermCount == 1)
        #expect(process.sigkillCount == 1)
        #expect(!handle.isActive)
    }

    @Test("unexpected exit emits processExited with the code and stderr")
    func unexpectedExit() async throws {
        let process = FakePluginProcess()
        process.stderr = "boom: connection reset"
        try process.start()
        let handle = BundledPluginTunnelHandle(process: process, gracePeriod: .milliseconds(50), pollInterval: .milliseconds(1))

        process.simulateExit(code: 1)

        #expect(!handle.isActive)
        var reasons: [TunnelDropReason] = []
        for await reason in handle.onDisconnect { reasons.append(reason) }
        #expect(reasons == [.processExited(code: 1, stderr: "boom: connection reset")])
    }
}

/// Creates a temporary file for plugin-path tests, optionally with the executable bit set.
private enum TempFile {
    static func make(executable: Bool) throws -> String {
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("plugin-\(UUID().uuidString)").path
        let perms = executable ? 0o755 : 0o644
        FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: perms])
        return path
    }
}
