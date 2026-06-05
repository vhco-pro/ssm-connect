import Foundation
import Testing
@testable import SSMConnect

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

    @Test("seedIfEmpty seeds one profile from a parsed config and marks it active")
    func seedFromConfig() {
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

        store.seedIfEmpty(parser: parser)

        #expect(store.profiles.count == 1)
        let seeded = store.activeProfile
        #expect(seeded.ssoStartUrl == "https://example.awsapps.com/start")
        #expect(seeded.ssoRegion == "eu-west-1")
        #expect(seeded.resourceRegion == "eu-central-1")
        #expect(store.activeProfileID == seeded.id)
    }

    @Test("seedIfEmpty falls back to the factory default when no config is available")
    func seedFallback() {
        let store = ProfileStore(defaults: makeDefaults())
        store.seedIfEmpty(parser: nil)

        #expect(store.profiles.count == 1)
        #expect(store.activeProfile.instanceTagValue == ConnectionProfile.factoryDefault.instanceTagValue)
    }

    @Test("seedIfEmpty is a no-op when profiles already exist")
    func seedNoOp() {
        let store = ProfileStore(defaults: makeDefaults())
        store.addProfile(.factoryDefault)
        store.seedIfEmpty(parser: nil)
        #expect(store.profiles.count == 1)
    }

    @Test("add/update/duplicate/delete behave correctly")
    func crud() {
        let store = ProfileStore(defaults: makeDefaults())
        var p = ConnectionProfile.factoryDefault
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
        var p = ConnectionProfile.factoryDefault
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

    @Test("the last profile cannot be deleted out from under the active selection silently")
    func deleteLeavesActiveValid() {
        let store = ProfileStore(defaults: makeDefaults())
        store.seedIfEmpty(parser: nil)
        let onlyID = store.profiles[0].id
        store.deleteProfile(onlyID)
        #expect(store.profiles.isEmpty)
        // activeProfile falls back to the factory default rather than crashing.
        #expect(store.activeProfile.name == ConnectionProfile.factoryDefault.name)
    }
}

@Suite("ConnectionProfile Codable")
struct ConnectionProfileCodableTests {
    @Test("round-trips through JSON including the connect action")
    func roundTrip() throws {
        let original = ConnectionProfile.factoryDefault
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
