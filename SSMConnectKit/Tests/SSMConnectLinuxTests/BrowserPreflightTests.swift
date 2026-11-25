#if os(Linux)
import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectHelperCore
@testable import SSMConnectLinux
@testable import SSMConnectWorkflow

/// The managed-browser preflight on Linux with the real browser discovery (T79, AC-25): an installed
/// Chrome at an unsupported version is refused naming the browser, and the only process started
/// before the refusal is the discovery's `--version` probe.
@Suite("Linux browser preflight")
@MainActor
struct BrowserPreflightTests {
    @Test("An unsupported Chrome is refused naming the browser after only its --version probe")
    func unsupportedChromeRefusedAfterOnlyTheVersionProbe() throws {
        let root = try LinuxAdapterTests.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let starts = root.appendingPathComponent("starts.log")
        let chrome = root.appendingPathComponent("google/chrome/chrome")
        // A Chrome that records every start with its arguments and reports a version no run pinned.
        try LinuxAdapterTests.executable(chrome, """
            #!/bin/sh
            echo "$*" >> '\(starts.path)'
            echo "Google Chrome 1.2.3.4"
            """)
        let discovery = LinuxBrowserDiscovery(candidates: .init(chrome: [chrome], zen: []))
        // The production wiring: the helper's browser preflight asks discovery for a supported executable.
        let opener = ShellBrowserOpener(requests: ShellRequests(), executable: { profile in
            guard let choice = profile.webForwards?.browser, let mode = profile.webForwards?.browserMode else { return nil }
            return discovery.supported(choice, mode: mode)?.executable.path
        }, profiles: root.appendingPathComponent("Browsers", isDirectory: true))
        var profile = ConnectionProfile(name: "Workstation", ssoStartUrl: "https://d-0123456789.awsapps.com/start",
                                        ssoRegion: "eu-west-1", accountId: "111122223333", roleName: "Admin",
                                        resourceRegion: "eu-central-1", instanceTagKey: "Name", instanceTagValue: "ws",
                                        secretId: "ec2/workstation-dcv-password", localPort: 18443, remotePort: 8443)
        profile.webForwards = .init(enabled: true, sshUser: "ec2-user", browser: .chrome, browserMode: .separate)

        #expect(throws: CapabilityError.missing(.browser)) { try opener.preflight(profile: profile) }
        let recorded = (try? String(contentsOf: starts, encoding: .utf8)) ?? ""
        #expect(recorded.split(separator: "\n").map(String.init) == ["--version"])
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Browsers").path))
    }
}
#endif
