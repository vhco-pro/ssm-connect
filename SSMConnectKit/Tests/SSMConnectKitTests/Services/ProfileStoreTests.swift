import Foundation
import Testing
@testable import SSMConnectKit

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTests {

    /// A throwaway `UserDefaults` suite per test, cleaned up immediately.
    private func makeDefaults() -> UserDefaults {
        let suite = "ssmconnect.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("a fresh store has no profiles — nothing about an AWS env is baked in")
    func startsEmpty() {
        let store = ProfileStore(defaults: makeDefaults())
        #expect(store.profiles.isEmpty)
        #expect(store.hasProfiles == false)
        // activeProfile falls back to a blank template (not connectable).
        #expect(store.activeProfile.isConfigured == false)
    }

    @Test("importableProfiles maps ~/.aws/config SSO profiles, leaving tag + secret blank")
    func importFromConfig() {
        let store = ProfileStore(defaults: makeDefaults())
        let parser = AWSConfigParser(contents: """
        [profile workstation-prd]
        sso_session = sess
        sso_account_id = 111122223333
        sso_role_name = AdministratorAccess
        region = eu-central-1
        [sso-session sess]
        sso_start_url = https://example.awsapps.com/start
        sso_region = eu-west-1
        """)

        let importable = store.importableProfiles(parser: parser)

        #expect(importable.count == 1)
        let p = importable[0]
        #expect(p.name == "workstation-prd")
        #expect(p.ssoStartUrl == "https://example.awsapps.com/start")
        #expect(p.ssoRegion == "eu-west-1")
        #expect(p.accountId == "111122223333")
        #expect(p.resourceRegion == "eu-central-1")
        // Config doesn't carry these — left for the user.
        #expect(p.instanceTagValue.isEmpty)
        #expect(p.secretId == nil)
        #expect(p.isConfigured == false)
    }

    @Test("importableProfiles is empty when no config is available")
    func importNoConfig() {
        let store = ProfileStore(defaults: makeDefaults())
        #expect(store.importableProfiles(parser: nil).isEmpty)
    }

    @Test("add/update/duplicate/delete behave correctly")
    func crud() {
        let store = ProfileStore(defaults: makeDefaults())
        var p = ConnectionProfile.example
        p.id = UUID()
        store.addProfile(p)
        #expect(store.activeProfileID == p.id) // first add becomes active

        p.name = "Renamed"
        store.updateProfile(p)
        #expect(store.profiles.first?.name == "Renamed")

        let copy = store.duplicateProfile(p.id)
        #expect(store.profiles.count == 2)
        #expect(copy?.name == "Renamed Copy")
        #expect(copy?.id != p.id)

        store.deleteProfile(p.id)
        #expect(store.profiles.count == 1)
        #expect(store.activeProfileID == copy?.id) // active moved to the remaining profile
    }

    @Test("profiles and settings persist across store instances")
    func persistence() {
        let defaults = makeDefaults()
        let store = ProfileStore(defaults: defaults)
        var p = ConnectionProfile.example
        p.id = UUID()
        p.name = "Persisted"
        store.addProfile(p)
        store.settings.autoConnect = true
        store.settings.clipboardAutoClearSeconds = 90

        let reloaded = ProfileStore(defaults: defaults)
        #expect(reloaded.profiles.first?.name == "Persisted")
        #expect(reloaded.activeProfileID == p.id)
        #expect(reloaded.settings.autoConnect == true)
        #expect(reloaded.settings.clipboardAutoClearSeconds == 90)
    }

    @Test("deleting the last profile leaves a safe blank-template fallback rather than crashing")
    func deleteLeavesActiveValid() {
        let store = ProfileStore(defaults: makeDefaults())
        store.addProfile(.example)
        let onlyID = store.profiles[0].id
        store.deleteProfile(onlyID)
        #expect(store.profiles.isEmpty)
        // activeProfile falls back to the blank template rather than crashing.
        #expect(store.activeProfile.name == ConnectionProfile.template.name)
    }
}

@Suite("ConnectionProfile Codable")
struct ConnectionProfileCodableTests {
    @Test("round-trips through JSON including the connect action")
    func roundTrip() throws {
        let original = ConnectionProfile.example
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(decoded == original)
        #expect(decoded.connectAction == .dcvViewer)
    }

    @Test("AppSettings round-trips through JSON")
    func settingsRoundTrip() throws {
        let original = AppSettings(autoConnect: true, autoReconnect: false, clipboardAutoClearSeconds: 45)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded == original)
    }
}
