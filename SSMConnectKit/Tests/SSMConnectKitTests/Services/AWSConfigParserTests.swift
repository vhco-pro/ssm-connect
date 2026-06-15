import Foundation
import Testing
@testable import SSMConnectKit

@Suite("AWSConfigParser")
struct AWSConfigParserTests {

    @Test("parses the newer sso-session format and merges the referenced block")
    func ssoSessionFormat() {
        let config = """
        [default]
        region = eu-west-1

        [profile workstation-prd]
        sso_session = d-0123456789
        sso_account_id = 111122223333
        sso_role_name = AdministratorAccess
        region = eu-central-1

        [sso-session d-0123456789]
        sso_start_url = https://d-0123456789.awsapps.com/start
        sso_region = eu-west-1
        sso_registration_scopes = sso:account:access
        """

        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "workstation-prd")

        #expect(resolved?.startUrl == "https://d-0123456789.awsapps.com/start")
        #expect(resolved?.ssoRegion == "eu-west-1")
        #expect(resolved?.accountId == "111122223333")
        #expect(resolved?.roleName == "AdministratorAccess")
        #expect(resolved?.resourceRegion == "eu-central-1")
    }

    @Test("parses the legacy inline sso_start_url format")
    func legacyInlineFormat() {
        let config = """
        [profile legacy]
        sso_start_url = https://legacy.awsapps.com/start
        sso_region = us-east-1
        sso_account_id = 111122223333
        sso_role_name = ReadOnly
        region = us-east-2
        """

        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "legacy")

        #expect(resolved?.startUrl == "https://legacy.awsapps.com/start")
        #expect(resolved?.ssoRegion == "us-east-1")
        #expect(resolved?.accountId == "111122223333")
        #expect(resolved?.resourceRegion == "us-east-2")
    }

    @Test("ignores comments and blank lines")
    func commentsAndBlanks() {
        let config = """
        # top comment
        [profile p]   ; trailing comment
        sso_account_id = 123  # inline comment

        region = eu-central-1
        """

        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "p")

        #expect(resolved?.accountId == "123")
        #expect(resolved?.resourceRegion == "eu-central-1")
    }

    @Test("returns nil for an unknown profile")
    func unknownProfile() {
        let parser = AWSConfigParser(contents: "[profile a]\nregion = x")
        #expect(parser.resolvedProfile(named: "missing") == nil)
    }

    @Test("a profile referencing a missing sso-session still resolves its own keys")
    func missingSSOSessionBlock() {
        let config = """
        [profile orphan]
        sso_session = nope
        sso_account_id = 999
        region = eu-central-1
        """
        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "orphan")

        #expect(resolved?.startUrl == nil)
        #expect(resolved?.accountId == "999")
        #expect(resolved?.resourceRegion == "eu-central-1")
    }

    @Test("the default section is addressable as 'default'")
    func defaultSection() {
        let parser = AWSConfigParser(contents: "[default]\nregion = eu-west-1")
        #expect(parser.resolvedProfile(named: "default")?.resourceRegion == "eu-west-1")
    }

    @Test("resolvedProfiles lists only SSO profiles, sorted, for the import picker")
    func listsSSOProfiles() {
        let config = """
        [sso-session sess]
        sso_start_url = https://x.awsapps.com/start
        sso_region = eu-west-1

        [profile zeta]
        sso_session = sess
        sso_account_id = 111
        region = eu-central-1

        [profile alpha]
        sso_session = sess
        sso_account_id = 222
        region = eu-west-1

        [profile no-sso]
        region = us-east-1
        """
        let parser = AWSConfigParser(contents: config)
        let names = parser.resolvedProfiles().map(\.name)

        // Sorted, and the SSO-less profile is excluded.
        #expect(names == ["alpha", "zeta"])
    }
}
