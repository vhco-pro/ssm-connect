import Foundation
import SSMConnectDomain

/// The proxy auto-config file for web forwards: the configured suffixes through the SOCKS
/// listener, everything else direct.
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
