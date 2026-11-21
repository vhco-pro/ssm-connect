import Foundation
import SSMConnectDomain

/// OpenSSH's command line for web forwards, shared by every platform: key-only, batch mode, the
/// Session Manager plugin as ProxyCommand, a SOCKS listener and the local forwards, all bound to
/// 127.0.0.1. The style covers how each platform's OpenSSH reads ProxyCommand and its null device.
package enum SSHArguments {
    package enum Style: Sendable {
        /// POSIX shells: single-quoted words, `/dev/null`.
        case posix
        /// Windows OpenSSH: double-quoted words, `NUL`.
        case windows
    }

    package static let sshDocument = "AWS-StartSSHSession"

    package static func webForwards(pluginPath: String, region: String, instanceId: String, user: String,
                                    keyPath: String, configuration: WebForwardsConfiguration, style: Style) throws -> [String] {
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        guard AWSRegion.isValid(region), ProfileEditorValidation.safeHost(user),
              ProfileEditorValidation.safeHost(instanceId), !pluginPath.contains("%"),
              !pluginPath.contains(where: \.isNewline), !pluginPath.contains("\"") else {
            throw WebForwardsError.invalidConfiguration("Invalid SSH user, instance, region or plugin path.")
        }
        let request: [String: Any] = ["Target": instanceId, "DocumentName": sshDocument,
                                      "Parameters": ["portNumber": ["22"]]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let proxy = [pluginPath, "AWS_SSM_START_SESSION_RESPONSE", region, "StartSession", "", json]
            .map { quote($0, style) }.joined(separator: " ")
        var arguments = ["-N", "-T", "-i", keyPath, "-o", "IdentitiesOnly=yes",
                         "-o", "BatchMode=yes", "-o", "ProxyCommand=\(proxy)",
                         "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30",
                         "-o", "ServerAliveCountMax=3", "-o", "StrictHostKeyChecking=no",
                         "-o", "UserKnownHostsFile=\(style == .windows ? "NUL" : "/dev/null")", "-o", "LogLevel=ERROR"]
        if let port = configuration.socksPort { arguments += ["-D", "127.0.0.1:\(port)"] }
        for forward in configuration.localForwards {
            arguments += ["-L", "127.0.0.1:\(forward.localPort):\(forward.remoteHost):\(forward.remotePort)"]
        }
        return arguments + ["\(user)@\(instanceId)"]
    }

    static func quote(_ value: String, _ style: Style) -> String {
        switch style {
        case .posix: "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
        case .windows: "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
    }
}
