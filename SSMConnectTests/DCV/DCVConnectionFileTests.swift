import Testing
@testable import SSMConnect

@Suite("DCVConnectionFile")
struct DCVConnectionFileTests {
    @Test("INI content carries the auto-login [connect] fields")
    func iniContent() {
        let file = DCVConnectionFile(port: 8443, password: "p@ss w0rd")
        let ini = file.iniContent()

        #expect(ini.contains("[connect]"))
        #expect(ini.contains("host=localhost"))
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
}
