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

    // Verifies: Fix opaque region-failure on Connect, Criterion: "A `[profile]` with `region = eu-central-1 ` (trailing space), parsed by `AWSConfigParser`, yields `resourceRegion == "eu-central-1"` (trimmed, valid)."
    @Test("a region with surrounding whitespace resolves to the trimmed, valid value")
    func trimsRegionWhitespace() {
        // The `region` and `sso_region` values carry trailing/leading spaces.
        let config = "[profile ws]\n"
            + "sso_session = ws\n"
            + "sso_account_id = 111122223333\n"
            + "region = eu-central-1  \n"
            + "\n"
            + "[sso-session ws]\n"
            + "sso_start_url = https://ws.awsapps.com/start\n"
            + "sso_region =   eu-west-1  \n"
        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "ws")

        #expect(resolved?.resourceRegion == "eu-central-1")
        #expect(resolved?.ssoRegion == "eu-west-1")
        #expect(AWSRegion.isValid(resolved?.resourceRegion ?? "") == true)
        #expect(AWSRegion.isValid(resolved?.ssoRegion ?? "") == true)
    }

    // Verifies: Fix opaque region-failure on Connect, Criterion: "A profile omitting the `region` key, parsed then validated, yields `resourceRegion == ""` and `AWSRegion.isValid("")` returns `false`."
    @Test("a profile omitting the region key yields no resource region and fails validation")
    func omittedRegionIsInvalid() {
        let config = """
        [sso-session sess]
        sso_start_url = https://x.awsapps.com/start
        sso_region = eu-west-1

        [profile no-region]
        sso_session = sess
        sso_account_id = 111122223333
        sso_role_name = AdministratorAccess
        """
        let parser = AWSConfigParser(contents: config)
        let resolved = parser.resolvedProfile(named: "no-region")

        #expect(resolved?.resourceRegion == nil)
        // A ConnectionProfile built from this config gets resourceRegion "", which is invalid.
        let profile = ConnectionProfile(name: "no-region", awsConfig: resolved!)
        #expect(profile.resourceRegion == "")
        #expect(AWSRegion.isValid(profile.resourceRegion) == false)
        #expect(profile.isConfigured == false)
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
