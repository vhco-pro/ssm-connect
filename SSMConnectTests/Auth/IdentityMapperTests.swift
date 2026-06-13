import Testing
@testable import SSMConnect

/// These cases mirror the agent's Go tests (vhco-pro/workstation-agent,
/// internal/identity) so the two implementations provably agree.
@Suite("IdentityMapper")
struct IdentityMapperTests {
    @Test("SSO assumed-role with email session name -> local-part")
    func ssoEmail() throws {
        let arn = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_AdministratorAccess_abc/alice@example.com"
        #expect(try IdentityMapper.username(fromARN: arn) == "alice")
    }

    @Test("Hyphen suffix is kept (org-agnostic default, not stripped)")
    func hyphenSuffix() throws {
        let arn = "arn:aws:sts::823091238322:assumed-role/AWSReservedSSO_PowerUserAccess_x/DL6544-A@engie.com"
        #expect(try IdentityMapper.username(fromARN: arn) == "dl6544-a")
    }

    @Test("Instance-role session name (instance id) passes through")
    func instanceId() throws {
        let arn = "arn:aws:sts::123456789012:assumed-role/workstation-role/i-00c45ce9e5a87cd60"
        #expect(try IdentityMapper.username(fromARN: arn) == "i-00c45ce9e5a87cd60")
    }

    @Test("No slash -> error")
    func noSlash() {
        #expect(throws: IdentityMapper.MappingError.noRoleSessionName) {
            try IdentityMapper.username(fromARN: "not-an-arn")
        }
    }

    @Test("Trailing slash -> error")
    func trailingSlash() {
        #expect(throws: IdentityMapper.MappingError.noRoleSessionName) {
            try IdentityMapper.username(fromARN: "arn:aws:sts::1:assumed-role/role/")
        }
    }

    @Test("All-symbol session name -> error")
    func allSymbols() {
        #expect(throws: IdentityMapper.MappingError.emptyAfterSanitize) {
            try IdentityMapper.username(fromARN: "arn:aws:sts::1:assumed-role/role/@@@")
        }
    }

    @Test("Sanitize is deterministic and drops disallowed chars")
    func sanitizeStable() throws {
        #expect(try IdentityMapper.sanitize("Alice.Smith+test@example.com") == "alicesmithtest")
    }

    @Test("Sanitize truncates to 32 chars")
    func sanitizeTruncates() throws {
        let long = String(repeating: "a", count: 50)
        #expect(try IdentityMapper.sanitize(long).count == 32)
    }
}
