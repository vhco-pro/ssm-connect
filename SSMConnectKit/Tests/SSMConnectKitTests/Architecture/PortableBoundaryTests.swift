import Foundation
import Testing

/// Enforces the half of AC-02 the target split cannot enforce.
///
/// Phase 2 split the package into `SSMConnectDomain` / `SSMConnectWorkflow` / `SSMConnectAWS` /
/// `SSMConnectMacOS` / `SSMConnectUI`. That split gives a real compiler barrier for the AWS SDK:
/// the portable targets do not depend on `aws-sdk-swift`, so `import AWSEC2` in either of them
/// fails to build. Verified, not assumed.
///
/// It does **not** give one for Apple frameworks. `AppKit`, `SwiftUI`, `Darwin`,
/// `ServiceManagement`, `UserNotifications`, `Network`, and `os` come from the platform SDK rather
/// than from a package dependency, so they are importable by any target compiled on macOS
/// regardless of what `Package.swift` declares. Adding `import SwiftUI` to `SSMConnectWorkflow`
/// compiles cleanly today; only this test stops it.
///
/// So the boundary is enforced in two places, and this is the second one. It scans directories
/// rather than a hand-maintained file list on purpose: a list silently stops covering anything
/// added after it was written, which is the failure mode that would let the boundary rot unnoticed.
///
/// The genuinely stronger check is compiling these two targets for Linux, where the Apple
/// frameworks do not exist at all. That is not wired up — see the Phase 2 notes in the
/// specification for what currently blocks it.
@Suite("Portable layer import boundary")
struct PortableBoundaryTests {
    /// The targets §5.2 requires to stay portable.
    static let portableTargets = ["SSMConnectDomain", "SSMConnectWorkflow"]

    /// Everything AC-02 names, plus the platform networking and logging modules §5.2 rules out,
    /// plus the AWS SDK modules (belt and braces — the compiler already rejects those).
    static let forbiddenImports: Set<String> = [
        "AppKit", "SwiftUI", "ServiceManagement", "UserNotifications", "Darwin",
        "Network", "os", "CoreFoundation", "CryptoKit",
        "AWSEC2", "AWSSSM", "AWSSSO", "AWSSSOOIDC", "AWSSecretsManager",
        "AWSClientRuntime", "ClientRuntime", "Smithy", "SmithyHTTPAPI", "SmithyIdentity",
    ]

    static let sourcesRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Sources")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("SSMConnectDomain").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate Sources/ above \(#filePath).")
    }()

    static func swiftFiles(in target: String) -> [URL] {
        let directory = sourcesRoot.appendingPathComponent(target)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    static func imports(of file: URL) throws -> Set<String> {
        let contents = try String(contentsOf: file, encoding: .utf8)
        let pattern = try NSRegularExpression(
            pattern: #"^\s*(?:@[^\s]+\s+)*import\s+(?:struct|class|enum|protocol|func|var|let|typealias\s+)?\s*([A-Za-z_][A-Za-z0-9_]*)"#,
            options: [.anchorsMatchLines]
        )
        let range = NSRange(contents.startIndex..., in: contents)
        return Set(pattern.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { String(contents[$0]) }
        })
    }

    @Test("each portable target has sources, so a moved directory cannot empty this check",
          arguments: portableTargets)
    func targetHasSources(target: String) {
        #expect(
            !Self.swiftFiles(in: target).isEmpty,
            "No Swift files found in Sources/\(target). If the target was renamed, update this test rather than letting the boundary check silently pass over nothing."
        )
    }

    @Test("no portable source imports a platform or AWS module", arguments: portableTargets)
    func portableTargetsStayPortable(target: String) throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(in: target) {
            let forbidden = try Self.imports(of: file).intersection(Self.forbiddenImports)
            if !forbidden.isEmpty {
                offenders.append("\(file.lastPathComponent) imports \(forbidden.sorted().joined(separator: ", "))")
            }
        }

        let detail = offenders.joined(separator: "\n  ")
        #expect(
            offenders.isEmpty,
            "[AC-02] \(target) must depend on Foundation and the domain only. Put the platform code behind a port and implement it in an adapter target.\n  \(detail)"
        )
    }
}
