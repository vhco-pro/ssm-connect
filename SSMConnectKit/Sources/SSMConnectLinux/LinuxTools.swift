#if os(Linux)
import Foundation
import SSMConnectWorkflow

/// The external programs the Linux client starts: the Session Manager plugin and the editor proxy
/// bundled beside the helper, the distribution's OpenSSH client, VS Code's `code` launcher and
/// DCV Viewer, found on PATH and then in their usual install folders.
package struct LinuxTools: Sendable {
    package var helperDirectory: URL
    package var environment: [String: String]
    package var fallbackDirectories: [String]

    /// The folder of the running executable, through /proc so a symbolic link does not hide it.
    package static var executableDirectory: URL {
        URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath().deletingLastPathComponent()
    }

    package init(helperDirectory: URL = LinuxTools.executableDirectory,
                 environment: [String: String] = ProcessInfo.processInfo.environment,
                 fallbackDirectories: [String] = ["/usr/bin", "/usr/share/code/bin", "/snap/bin"]) {
        self.helperDirectory = helperDirectory
        self.environment = environment
        self.fallbackDirectories = fallbackDirectories
    }

    private func bundled(_ name: String) -> String? {
        let path = helperDirectory.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// The first executable file with this name on PATH, then in the fallback folders.
    package func find(_ name: String) -> String? {
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
        return (path + fallbackDirectories).lazy
            .map { URL(fileURLWithPath: $0).appendingPathComponent(name).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    package var pluginPath: String? { bundled("session-manager-plugin") }
    package var proxyPath: String? { bundled("ssm-connect-proxy") }
    package var sshPath: String? { find("ssh") }
    package var sshKeygenPath: String? { find("ssh-keygen") }
    package var vsCodePath: String? { find("code") }
    package var dcvViewerPath: String? { find("dcvviewer") }

    /// Which of the capabilities are missing on this machine (AC-25 preflight input).
    package func missing(_ capabilities: [Capability]) -> [Capability] {
        capabilities.filter { capability in
            switch capability {
            case .sessionManagerPlugin: pluginPath == nil
            case .openSSH: sshPath == nil || sshKeygenPath == nil
            case .visualStudioCode: vsCodePath == nil
            case .browser: LinuxBrowserDiscovery().installedSupported().isEmpty
            }
        }
    }
}
#endif
