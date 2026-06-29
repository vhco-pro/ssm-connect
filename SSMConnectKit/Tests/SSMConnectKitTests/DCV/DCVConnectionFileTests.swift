import Testing
@testable import SSMConnectKit

@Suite("DCVConnectionFile")
struct DCVConnectionFileTests {
    @Test("INI content carries the auto-login [connect] fields")
    func iniContent() {
        let file = DCVConnectionFile(port: 8443, password: "p@ss w0rd")
        let ini = file.iniContent()

        #expect(ini.contains("[connect]"))
        #expect(ini.contains("host=127.0.0.1"))
        #expect(ini.contains("port=8443"))
        #expect(ini.contains("user=ec2-user"))
        #expect(ini.contains("password=p@ss w0rd"))
        #expect(ini.contains("weburlpath=/"))
        #expect(ini.contains("format=1.0"))
    }

    @Test("Custom host/user/port are honored")
    func customFields() {
        let file = DCVConnectionFile(host: "127.0.0.1", port: 9000, user: "alice", password: "x")
        let ini = file.iniContent()
        #expect(ini.contains("host=127.0.0.1"))
        #expect(ini.contains("port=9000"))
        #expect(ini.contains("user=alice"))
    }

    @Test("Vanilla factory still emits password and no token fields")
    func vanillaMode() {
        let ini = DCVConnectionFile.vanilla(port: 8443, password: "secret").iniContent()
        #expect(ini.contains("user=ec2-user"))
        #expect(ini.contains("password=secret"))
        #expect(!ini.contains("authtoken="))
        #expect(!ini.contains("sessionid="))
    }

    @Test("Multi-user factory emits sessionid + authtoken and no password")
    func multiUserMode() {
        let ini = DCVConnectionFile.multiUser(port: 8443, user: "dl6544", sessionId: "dl6544", authToken: "TOK123").iniContent()
        #expect(ini.contains("user=dl6544"))
        #expect(ini.contains("sessionid=dl6544"))
        #expect(ini.contains("authtoken=TOK123"))
        #expect(!ini.contains("password="))
    }

    /// Regression guard for the IPv6-localhost bug (docs/specs/bug-ipv6-localhost-*): the SSM
    /// port-forward binds IPv4 `127.0.0.1` only, so the `.dcv` host must be the IPv4 loopback —
    /// `localhost` resolves to `::1` first on macOS and the Viewer fails "endpoint is unreachable".
    @Test("Default host is the IPv4 loopback (not localhost) on all entry points")
    func defaultHostIsIPv4Loopback() {
        #expect(DCVConnectionFile(port: 8443, password: "x").iniContent().contains("host=127.0.0.1"))
        #expect(DCVConnectionFile.vanilla(port: 8443, password: "x").iniContent().contains("host=127.0.0.1"))
        #expect(DCVConnectionFile.multiUser(port: 8443, user: "u", sessionId: "u", authToken: "t").iniContent().contains("host=127.0.0.1"))
    }
}
