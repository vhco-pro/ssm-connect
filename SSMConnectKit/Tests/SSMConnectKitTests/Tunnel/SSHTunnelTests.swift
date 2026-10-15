import Foundation
import Testing
@testable import SSMConnectKit

@Suite("Web forwards transport")
struct SSHTunnelTests {
    struct SpawnedPortProbe: PortProbing {
        let process: FakePluginProcess
        func occupant(of port: Int) -> PortOccupant? {
            process.isRunning ? .init(pid: process.processIdentifier, processName: "ssh") : nil
        }
    }

    let configuration = WebForwardsConfiguration(enabled: true, proxySuffixes: [".internal.example.com"],
        localForwards: [.init(name: "Dashboard", localPort: 4466, remoteHost: "127.0.0.1", remotePort: 4466, openPath: "/")])

    @Test("AC-2: pure SSH arguments use loopback forwards and environment response without a session token")
    func arguments() throws {
        let arguments = try SSHTunnel.arguments(pluginPath: "/Applications/SSM Connect.app/Contents/Helpers/plugin",
            region: "eu-central-1", instanceId: "i-0123456789abcdef0", user: "alice", keyPath: "/tmp/key",
            configuration: configuration)
        #expect(arguments.contains("127.0.0.1:1080"))
        #expect(arguments.contains("127.0.0.1:4466:127.0.0.1:4466"))
        let proxy = try #require(arguments.first { $0.hasPrefix("ProxyCommand=") })
        #expect(proxy.contains("'AWS_SSM_START_SESSION_RESPONSE' 'eu-central-1' 'StartSession' ''"))
        #expect(proxy.contains("AWS-StartSSHSession"))
        #expect(!arguments.joined().contains(SSMSessionResponse.stub().tokenValue))
        #expect(!arguments.contains("-f"))
    }

    @Test("AC-6: PAC internal branches contain no DIRECT fallback")
    func pac() throws {
        let pac = try WebForwardsPAC.contents(configuration: configuration)
        let internalLines = pac.split(separator: "\n").filter { $0.contains("dnsDomainIs") }
        #expect(internalLines.count == 1)
        #expect(internalLines.allSatisfy { $0.contains("SOCKS5 127.0.0.1:1080") && !$0.contains("DIRECT") })
        #expect(pac.contains("return \"DIRECT\";"))
    }

    @Test("WF-12: spawned SSH gets the session token only through its environment")
    func sessionEnvironment() async throws {
        let spawner = FakePluginSpawner()
        let tunnel = SSHTunnel(pluginPath: { "/usr/bin/true" }, spawner: spawner,
                               portProbe: SpawnedPortProbe(process: spawner.process))
        let session = SSMSessionResponse.stub(tokenValue: "secret-session-token")
        let handle = try await tunnel.start(session: session, region: "eu-central-1", instanceId: "i-test",
            user: "alice", keyPath: "/tmp/key", configuration: configuration)
        #expect(spawner.lastExecutablePath == "/usr/bin/ssh")
        let environmentJSON = try #require(spawner.process.environment["AWS_SSM_START_SESSION_RESPONSE"])
        let response = try JSONDecoder().decode([String: String].self, from: Data(environmentJSON.utf8))
        #expect(response == ["SessionId": session.sessionId, "StreamUrl": session.streamUrl,
                     "TokenValue": session.tokenValue])
        #expect(spawner.lastArguments?.joined().contains("secret-session-token") == false)
        await handle.terminate()
        #expect(handle.isActive == false)
    }

    @Test("WF-11: ports, suffixes and SSH/proxy injection are rejected")
    func validation() {
        var invalid = configuration
        invalid.socksPort = 4466
        #expect(ProfileEditorValidation.webForwardsError(invalid) != nil)
        invalid = configuration
        invalid.localForwards[0].remotePort = 65536
        #expect(ProfileEditorValidation.webForwardsError(invalid) != nil)
        invalid = configuration
        invalid.proxySuffixes = [".example.com\"); return \"DIRECT"]
        #expect(ProfileEditorValidation.webForwardsError(invalid) != nil)
        invalid = configuration
        invalid.sshUser = "alice%h"
        #expect(ProfileEditorValidation.webForwardsError(invalid) != nil)
    }

    @Test("WF-8: an occupied port fails before spawning SSH")
    func occupiedPort() async {
        let spawner = FakePluginSpawner()
        let tunnel = SSHTunnel(pluginPath: { "/usr/bin/true" }, spawner: spawner,
            portProbe: StubPortProbe(occupantToReturn: .init(pid: 99, processName: "other")))
        await #expect(throws: TunnelError.localPortInUse(port: 4466, pid: 99, processName: "other")) {
            try await tunnel.start(session: .stub(), region: "eu-central-1", instanceId: "i-test",
                                   user: "alice", keyPath: "/tmp/key", configuration: configuration)
        }
        #expect(spawner.spawnCount == 0)
    }

    @Test("WF-13: generated keys have restricted permissions and are removed")
    func ephemeralKey() async throws {
        let key = try await SSHKeyGenerator().generate()
        defer { key.remove() }
        let attributes = try FileManager.default.attributesOfItem(atPath: key.directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(key.publicKey.hasPrefix("ssh-ed25519 "))
        #expect(FileManager.default.fileExists(atPath: key.privateKeyPath))
        key.remove()
        #expect(!FileManager.default.fileExists(atPath: key.privateKeyPath))
    }
}