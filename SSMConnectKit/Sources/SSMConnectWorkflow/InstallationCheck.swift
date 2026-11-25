import Crypto
import Foundation

/// Why a launch was refused: a file it would start belongs to another build, or is gone.
package enum InstallationChange: Error, LocalizedError, Equatable {
    case updated
    case removed

    package var errorDescription: String? {
        switch self {
        case .updated: "SSM Connect was updated; restart it."
        case .removed: "SSM Connect was removed; quit it."
        }
    }
}

/// The check of the exact file before each launch (Design, Migration, performance and release
/// boundaries). An executable SSM Connect starts must carry this build's ID, and the bundled
/// plugin must have the SHA-256 this build recorded. So a half-replaced or interrupted install
/// never starts a mixed build: an action whose file was replaced is refused as updated, one whose
/// file was removed as removed, and an action whose files are unchanged proceeds.
package struct InstallationCheck: Sendable {
    static let prefix = "ssm-connect-build:"

    package var build: String
    package var pluginSHA256: String?

    package init(build: String = InstalledBuild.current, pluginSHA256: String? = InstalledBuild.pluginSHA256) {
        self.build = build
        self.pluginSHA256 = pluginSHA256
    }

    /// The bytes every executable of `build` contains.
    package static func marker(for build: String) -> Data { Data((prefix + build + ";").utf8) }

    /// The build ID inside a marker literal.
    package static func build(inMarker marker: String) -> String {
        String(marker.dropFirst(prefix.count).dropLast())
    }

    /// Lowercase hexadecimal SHA-256.
    package static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Refuses unless the executable at `path` carries this build's ID.
    package func executable(at path: String) throws {
        guard try Self.contents(path).range(of: Self.marker(for: build)) != nil else { throw InstallationChange.updated }
    }

    /// Refuses unless the plugin at `path` exists and, in a release build, has the recorded hash.
    package func plugin(at path: String) throws {
        let data = try Self.contents(path)
        guard let expected = pluginSHA256 else { return }
        guard Self.sha256(data) == expected.lowercased() else { throw InstallationChange.updated }
    }

    private static func contents(_ path: String) throws -> Data {
        guard FileManager.default.fileExists(atPath: path) else { throw InstallationChange.removed }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            throw InstallationChange.updated
        }
        return data
    }
}
