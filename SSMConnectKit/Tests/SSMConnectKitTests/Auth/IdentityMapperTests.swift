import Testing
@testable import SSMConnectKit

/// These cases mirror the agent's Go tests (vhco-pro/workstation-agent,
/// internal/identity) so the two implementations provably agree (reject-based).
@Suite("IdentityMapper")
struct IdentityMapperTests {
    @Test("Clean SSO names map to their local-part")
    func clean() throws {
        #expect(try IdentityMapper.username(fromARN: "arn:aws:sts::123:assumed-role/AWSReservedSSO_x/alice@example.com") == "alice")
        #expect(try IdentityMapper.username(fromARN: "arn:aws:sts::823091238322:assumed-role/AWSReservedSSO_PowerUserAccess_x/DL6544-A@engie.com") == "dl6544-a")
        #expect(try IdentityMapper.username(fromARN: "arn:aws:sts::123:assumed-role/workstation-role/i-00c45ce9e5a87cd60") == "i-00c45ce9e5a87cd60")
        #expect(try IdentityMapper.sanitize("jane_doe") == "jane_doe")
    }

    @Test("No / trailing slash -> error")
    func noSession() {
        #expect(throws: IdentityMapper.MappingError.noRoleSessionName) {
            try IdentityMapper.username(fromARN: "not-an-arn")
        }
        #expect(throws: IdentityMapper.MappingError.noRoleSessionName) {
            try IdentityMapper.username(fromARN: "arn:aws:sts::1:assumed-role/role/")
        }
    }

    @Test("Ambiguous or unsafe names are rejected, not transformed")
    func rejectsUnsafe() {
        for bad in ["Alice.Smith+test@example.com", "a.l.i.c.e@example.com", "-foo@example.com",
                    "1abc@example.com", "@@@", "averyveryveryveryveryverylongusername33"] {
            #expect(throws: IdentityMapper.MappingError.unsafeUsername) {
                try IdentityMapper.sanitize(bad)
            }
        }
    }

    @Test("Reserved/system names are rejected")
    func rejectsReserved() {
        for bad in ["root", "daemon", "ec2-user", "nobody"] {
            #expect(throws: IdentityMapper.MappingError.reservedUsername) {
                try IdentityMapper.sanitize(bad)
            }
        }
    }
}
