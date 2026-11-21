#if os(Windows)
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// The external programs the Windows client starts, found where they are installed: the Session
/// Manager plugin bundled beside the helper, Windows' OpenSSH client, and VS Code's command-line
/// launcher from a per-user or machine install.
package struct WindowsTools: Sendable {
    package var helperDirectory: URL
    package var environment: [String: String]

    package init(helperDirectory: URL = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
                 environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.helperDirectory = helperDirectory
        self.environment = environment
    }

    private func existing(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0) }
    }

    private func path(_ variable: String, _ components: String...) -> String? {
        guard let base = environment[variable] ?? environment[variable.uppercased()] else { return nil }
        return components.reduce(URL(fileURLWithPath: base)) { $0.appendingPathComponent($1) }.nativePath
    }

    package var pluginPath: String? {
        existing([helperDirectory.appendingPathComponent("session-manager-plugin.exe").nativePath])
    }

    package var sshPath: String? { existing([path("SystemRoot", "System32", "OpenSSH", "ssh.exe")]) }

    package var sshKeygenPath: String? { existing([path("SystemRoot", "System32", "OpenSSH", "ssh-keygen.exe")]) }

    package var vsCodePath: String? {
        existing([path("LOCALAPPDATA", "Programs", "Microsoft VS Code", "bin", "code.cmd"),
                  path("ProgramFiles", "Microsoft VS Code", "bin", "code.cmd")])
    }

    /// Which of the capabilities are missing on this machine (AC-25 preflight input).
    package func missing(_ capabilities: [Capability]) -> [Capability] {
        capabilities.filter { capability in
            switch capability {
            case .sessionManagerPlugin: pluginPath == nil
            case .openSSH: sshPath == nil || sshKeygenPath == nil
            case .visualStudioCode: vsCodePath == nil
            case .browser: WindowsBrowserDiscovery(environment: environment).installedSupported().isEmpty
            }
        }
    }
}

/// Starts the plugin and SSH as child processes with the shared command lines.
package enum WindowsProcessLauncher {
    /// Starts a port-forwarding plugin session.
    package static func startPlugin(at path: String, session: SSMSessionResponse, region: String, instanceId: String,
                                    localPort: Int, remotePort: Int) throws -> Process {
        try start(path, arguments: PluginArguments.portForward(session: session, region: region, instanceId: instanceId,
                                                              localPort: localPort, remotePort: remotePort))
    }

    /// Starts an executable with arguments, its output discarded unless the caller attaches pipes.
    package static func start(_ path: String, arguments: [String], environment: [String: String]? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        try process.run()
        return process
    }
}
#endif
