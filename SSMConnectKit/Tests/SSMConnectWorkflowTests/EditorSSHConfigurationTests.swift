import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// The editor's SSH config entry quotes its ProxyCommand the way the platform's OpenSSH reads it:
/// single-quoted words for a POSIX shell, double-quoted words on Windows, where OpenSSH starts the
/// command without a shell and a single quote is an ordinary character (T28).
@Suite("Editor SSH configuration")
struct EditorSSHConfigurationTests {
    let lease = RemoteSSHLease(profile: ConnectionProfile(name: "Workstation", ssoStartUrl: "https://d-0123456789.awsapps.com/start",
                                                                  ssoRegion: "eu-west-1", accountId: "123456789012", roleName: "Developer",
                                                                  resourceRegion: "eu-west-1", instanceTagKey: "Name", instanceTagValue: "ws",
                                                                  localPort: 8443, remotePort: 8443), instanceID: "i-0123456789abcdef0", user: "example",
                               keyPath: "C:\\Users\\u\\AppData\\Local\\Temp\\ssm-connect-ssh-1\\key", pluginPath: "plugin",
                               ownerPID: 1, ownerLaunchDate: Date(), ownerBundleID: "test", generation: UUID(),
                               expiresAt: Date().addingTimeInterval(60))

    @Test("Windows: the proxy and lease paths are double-quoted, with % doubled for OpenSSH's tokens")
    func windows() throws {
        let contents = try RemoteSSHConfiguration.contents(
            lease: lease, leasePath: "C:\\Users\\u\\AppData\\Local\\SSM Connect\\RemoteAccess\\1\\lease.json",
            helperPath: "C:\\Users\\u\\AppData\\Local\\Programs\\SSM Connect 100%\\ssm-connect-proxy.exe",
            knownHostsPath: "C:\\Users\\u\\AppData\\Local\\SSM Connect\\RemoteAccess\\known-hosts", style: .windows)
        #expect(contents.contains(
            "  ProxyCommand \"C:\\Users\\u\\AppData\\Local\\Programs\\SSM Connect 100%%\\ssm-connect-proxy.exe\" --configuration \"C:\\Users\\u\\AppData\\Local\\SSM Connect\\RemoteAccess\\1\\lease.json\"\n"))
        #expect(!contents.contains("'"))
    }

    @Test("POSIX: the proxy and lease paths are single-quoted")
    func posix() throws {
        let contents = try RemoteSSHConfiguration.contents(
            lease: lease, leasePath: "/tmp/it's/lease.json", helperPath: "/opt/SSM Connect/ssm-connect-proxy",
            knownHostsPath: "/tmp/known-hosts", style: .posix)
        #expect(contents.contains("  ProxyCommand '/opt/SSM Connect/ssm-connect-proxy' --configuration '/tmp/it'\\''s/lease.json'\n"))
    }

    @Test("Windows: a path with a double quote is refused")
    func windowsQuote() {
        #expect(throws: RemoteSSHError.self) {
            try RemoteSSHConfiguration.contents(lease: lease, leasePath: "C:\\a\"b\\lease.json", helperPath: "C:\\proxy.exe",
                                                knownHostsPath: "C:\\known-hosts", style: .windows)
        }
    }
}
