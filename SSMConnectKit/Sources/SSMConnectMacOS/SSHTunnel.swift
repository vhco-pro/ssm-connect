import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow


package struct SSHTunnel: SSHTunnelProviding {
    package var pluginPath: @Sendable () -> String? = { BundledPluginTunnel.defaultPluginPath() }
    package var spawner: PluginSpawning = ProcessPluginSpawner()
    package var portProbe: PortProbing = SystemPortProbe()
    package var readinessTimeout: Duration = .seconds(15)

    package func start(session: SSMSessionResponse, region: String, instanceId: String, user: String,
               keyPath: String, configuration: WebForwardsConfiguration) async throws -> TunnelHandle {
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        guard let path = pluginPath(), FileManager.default.isExecutableFile(atPath: path) else {
            throw TunnelError.pluginMissing(path: pluginPath() ?? "<unknown>")
        }
        let ports = configuration.localForwards.map(\.localPort) + (configuration.socksPort.map { [$0] } ?? [])
        for port in ports {
            if let occupant = portProbe.occupant(of: port) {
                throw TunnelError.localPortInUse(port: port, pid: occupant.pid, processName: occupant.processName)
            }
        }
        let arguments = try Self.arguments(pluginPath: path, region: region, instanceId: instanceId,
                                           user: user, keyPath: keyPath, configuration: configuration)
        let process = spawner.spawn(executablePath: "/usr/bin/ssh", arguments: arguments)
        process.setEnvironment(["AWS_SSM_START_SESSION_RESPONSE": try session.pluginSessionJSON()])
        let handle = BundledPluginTunnelHandle(process: process, gracePeriod: .seconds(5),
                                               pollInterval: .milliseconds(100))
        do {
            try handle.start()
            let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard handle.isActive else { throw WebForwardsError.sshNotReady }
                if ports.allSatisfy({ portProbe.occupant(of: $0)?.pid == handle.processIdentifier }) {
                    return handle
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw WebForwardsError.sshNotReady
        } catch {
            await handle.terminate()
            throw error
        }
    }

    package func unavailableCapabilities() -> [Capability] {
        var missing: [Capability] = []
        if pluginPath().map({ FileManager.default.isExecutableFile(atPath: $0) }) != true { missing.append(.sessionManagerPlugin) }
        if !FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") { missing.append(.openSSH) }
        return missing
    }

    package static func arguments(pluginPath: String, region: String, instanceId: String, user: String,
                          keyPath: String, configuration: WebForwardsConfiguration) throws -> [String] {
        try SSHArguments.webForwards(pluginPath: pluginPath, region: region, instanceId: instanceId, user: user,
                                     keyPath: keyPath, configuration: configuration, style: .posix)
    }

    package init(pluginPath: @escaping @Sendable () -> String? = { BundledPluginTunnel.defaultPluginPath() }, spawner: PluginSpawning = ProcessPluginSpawner(), portProbe: PortProbing = SystemPortProbe(), readinessTimeout: Duration = .seconds(15)) {
        self.pluginPath = pluginPath
        self.spawner = spawner
        self.portProbe = portProbe
        self.readinessTimeout = readinessTimeout
    }
}

package struct SSHKeyGenerator: SSHKeyGenerating {
    package func generate() async throws -> SSHKeyMaterial {
        try await Task.detached {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("ssm-connect-ssh-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            do {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
                process.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", directory.appendingPathComponent("key").path]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw WebForwardsError.keyGenerationFailed }
                let publicKey = try String(contentsOf: directory.appendingPathComponent("key.pub"), encoding: .utf8)
                return SSHKeyMaterial(directory: directory, publicKey: publicKey)
            } catch {
                try? FileManager.default.removeItem(at: directory)
                throw error
            }
        }.value
    }

    package init() {}
}
