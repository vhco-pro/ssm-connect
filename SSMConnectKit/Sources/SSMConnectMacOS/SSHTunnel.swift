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

    package static func arguments(pluginPath: String, region: String, instanceId: String, user: String,
                          keyPath: String, configuration: WebForwardsConfiguration) throws -> [String] {
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        guard AWSRegion.isValid(region), ProfileEditorValidation.safeHost(user),
              ProfileEditorValidation.safeHost(instanceId), !pluginPath.contains("%"),
              !pluginPath.contains(where: \.isNewline) else {
            throw WebForwardsError.invalidConfiguration("Invalid SSH user, instance, region or plugin path.")
        }
        let request: [String: Any] = ["Target": instanceId, "DocumentName": SSMService.sshDocument,
                                      "Parameters": ["portNumber": ["22"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let proxy = [pluginPath, "AWS_SSM_START_SESSION_RESPONSE", region, "StartSession", "", json]
            .map(shellQuote).joined(separator: " ")
        var arguments = ["-N", "-T", "-i", keyPath, "-o", "IdentitiesOnly=yes",
                         "-o", "BatchMode=yes", "-o", "ProxyCommand=\(proxy)",
                         "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                         "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=no",
                         "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR"]
        if let port = configuration.socksPort { arguments += ["-D", "127.0.0.1:\(port)"] }
        for forward in configuration.localForwards {
            arguments += ["-L", "127.0.0.1:\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"]
        }
        return arguments + ["\(user)@\(instanceId)"]
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

package enum WebForwardsPAC {
    package static func contents(configuration: WebForwardsConfiguration) throws -> String {
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        var lines = ["function FindProxyForURL(url, host) {", "  host = host.toLowerCase();"]
        if let port = configuration.socksPort {
            for suffix in configuration.proxySuffixes {
                lines.append("  if (dnsDomainIs(host, \"\(suffix.lowercased())\")) return \"SOCKS5 127.0.0.1:\(port)\";")
            }
        }
        return (lines + ["  return \"DIRECT\";", "}", ""]).joined(separator: "\n")
    }

    package static func write(configuration: WebForwardsConfiguration, profileID: UUID) throws -> URL {
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("SSMConnect/WebForwards", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(profileID.uuidString).pac")
        try BrowserPrivateFiles.write(Data(try contents(configuration: configuration).utf8), to: url)
        return url
    }
}