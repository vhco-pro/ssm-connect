import Foundation
import Testing

/// Enforces the portable-layer import boundary (AC-02, spec §5.2, MR-07).
///
/// Phase 2 splits `SSMConnectKit` into `SSMConnectDomain` / `SSMConnectWorkflow` / `SSMConnectAWS`
/// / `SSMConnectMacOS` / `SSMConnectUI`. That split is not finished — everything still compiles as
/// one target — so nothing yet *stops* a domain type from importing AppKit and quietly undoing the
/// work. Until the targets exist, this test is the boundary: the files listed below are the ones
/// destined for the portable targets, and they may not import an Apple UI/lifecycle framework, an
/// AWS SDK module, or platform networking.
///
/// When the physical targets land, delete this test — the compiler enforces it better.
@Suite("Portable layer import boundary")
struct PortableBoundaryTests {
    /// Files destined for `SSMConnectDomain`: values, states, validation, typed errors.
    static let domainFiles = [
        "Models/AWSCredentials.swift",
        "Models/AWSRegion.swift",
        "Models/AppSettings.swift",
        "Models/ConnectAction.swift",
        "Models/ConnectMode.swift",
        "Models/ConnectionProfile.swift",
        "Models/DCVConnectionFile.swift",
        "Models/EC2Instance.swift",
        "Models/ProfileConfigError.swift",
        "Models/SSMSessionResponse.swift",
        "Settings/ProfileEditorValidation.swift",
        "Auth/IdentityMapper.swift",
        "Logging/RingBuffer.swift",
        "StateMachine/ConnectionState.swift",
        "StateMachine/ErrorCategory.swift",
    ]

    /// Files destined for `SSMConnectWorkflow`: the orchestration plus the ports it depends on.
    static let workflowFiles = [
        "StateMachine/ConnectionStateMachine.swift",
        "StateMachine/ConnectionStateMachine+Menu.swift",
        "StateMachine/ConnectionTimeouts.swift",
        "Auth/AuthProviding.swift",
        "Auth/IdentityProviding.swift",
        "Services/AgentClienting.swift",
        "Services/EC2Providing.swift",
        "Services/SSMProviding.swift",
        "Services/SecretsProviding.swift",
        "Services/InstanceIdStore.swift",
        "Services/AWSErrorInterpreter.swift",
        "Tunnel/TunnelProvider.swift",
        "DCV/DCVLaunching.swift",
        "DCV/WorkstationReadiness.swift",
    ]

    /// Apple UI and lifecycle frameworks AC-02 names explicitly, plus the platform networking and
    /// AWS SDK modules §5.2 rules out of the workflow.
    static let forbiddenImports: Set<String> = [
        "AppKit", "SwiftUI", "ServiceManagement", "UserNotifications", "Darwin",
        "Network", "os",
        "AWSEC2", "AWSSSM", "AWSSSO", "AWSSSOOIDC", "AWSSecretsManager",
        "AWSClientRuntime", "ClientRuntime", "Smithy", "SmithyHTTPAPI", "SmithyIdentity",
    ]

    /// `AWSErrorInterpreter.swift` holds the one deliberate exception: it declares the
    /// `ErrorInterpreting` port *and* the SDK-facing adapter behind it. The adapter moves to
    /// `SSMConnectAWS` when the targets land; the protocol stays with the workflow.
    static let knownExceptions: Set<String> = ["Services/AWSErrorInterpreter.swift"]

    static let sourceRoot: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("Sources/SSMConnectKit")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Models").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate Sources/SSMConnectKit above \(#filePath).")
    }()

    static func imports(of relativePath: String) throws -> Set<String> {
        let url = sourceRoot.appendingPathComponent(relativePath)
        let contents = try String(contentsOf: url, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: #"^\s*(?:@[^\s]+\s+)*import\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: [.anchorsMatchLines])
        let range = NSRange(contents.startIndex..., in: contents)
        return Set(pattern.matches(in: contents, range: range).compactMap { match in
            Range(match.range(at: 1), in: contents).map { String(contents[$0]) }
        })
    }

    @Test("every listed portable file exists, so a rename cannot silently empty this check")
    func listedFilesExist() {
        for path in Self.domainFiles + Self.workflowFiles {
            let url = Self.sourceRoot.appendingPathComponent(path)
            #expect(
                FileManager.default.fileExists(atPath: url.path),
                "Portable file '\(path)' no longer exists. Update PortableBoundaryTests, do not delete the entry."
            )
        }
    }

    @Test("domain files import no UI, lifecycle, networking, or AWS SDK module", arguments: domainFiles)
    func domainStaysPortable(path: String) throws {
        let offending = try Self.imports(of: path).intersection(Self.forbiddenImports)
        #expect(
            offending.isEmpty,
            "[AC-02] Domain file '\(path)' imports \(offending.sorted().joined(separator: ", ")). A domain value cannot depend on a platform framework — move the platform part into an adapter."
        )
    }

    @Test("workflow files import no UI, lifecycle, networking, or AWS SDK module", arguments: workflowFiles)
    func workflowStaysPortable(path: String) throws {
        guard !Self.knownExceptions.contains(path) else { return }
        let offending = try Self.imports(of: path).intersection(Self.forbiddenImports)
        #expect(
            offending.isEmpty,
            "[AC-02] Workflow file '\(path)' imports \(offending.sorted().joined(separator: ", ")). The workflow depends on domain types and injected ports only — put the platform code behind a port."
        )
    }
}
