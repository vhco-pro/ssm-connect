import Foundation
import Testing
@testable import SSMConnectKit

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTests {

    /// Fresh, disk-free storage per test.
    ///
    /// This used to hand out a `UserDefaults(suiteName: "ssmconnect.tests.<uuid>")`. That is not
    /// actually throwaway: the suite gets registered with `cfprefsd` and flushed to
    /// `~/Library/Preferences/`, and the `removePersistentDomain` call ran *before* the test wrote
    /// anything, so it cleaned up nothing. Every CI and local run leaked one plist per test onto
    /// the developer's machine. Doing teardown afterwards does not fix it either, because it
    /// races the daemon's async flush. Staying off disk does.
    private func makeDefaults() -> InMemoryKeyValueStore {
        InMemoryKeyValueStore()
    }

    @Test("a fresh store has no profiles — nothing about an AWS env is baked in")
    func startsEmpty() {
        let store = ProfileStore(store: makeDefaults())
        #expect(store.profiles.isEmpty)
        #expect(store.hasProfiles == false)
        // activeProfile falls back to a blank template (not connectable).
        #expect(store.activeProfile.isConfigured == false)
    }

    @Test("empty-store fallback identity stays stable across reads and deleting the last profile")
    func stableFallbackIdentity() {
        let store = ProfileStore(store: makeDefaults())
        let fallback = store.activeProfile
        #expect(store.activeProfile == fallback)
        store.addProfile(.example)
        store.deleteProfile(store.profiles[0].id)
        #expect(store.activeProfile == fallback)
    }

    @Test("importableProfiles maps ~/.aws/config SSO profiles, leaving tag + secret blank")
    func importFromConfig() {
        let store = ProfileStore(store: makeDefaults())
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
        let store = ProfileStore(store: makeDefaults())
        #expect(store.importableProfiles(parser: nil).isEmpty)
    }

    @Test("add/update/duplicate/delete behave correctly")
    func crud() {
        let store = ProfileStore(store: makeDefaults())
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
        let store = ProfileStore(store: defaults)
        var p = ConnectionProfile.example
        p.id = UUID()
        p.name = "Persisted"
        store.addProfile(p)
        store.settings.autoConnect = true
        store.settings.clipboardAutoClearSeconds = 90

        let reloaded = ProfileStore(store: defaults)
        #expect(reloaded.profiles.first?.name == "Persisted")
        #expect(reloaded.activeProfileID == p.id)
        #expect(reloaded.settings.autoConnect == true)
        #expect(reloaded.settings.clipboardAutoClearSeconds == 90)
    }

    @Test("deleting the last profile leaves a safe blank-template fallback rather than crashing")
    func deleteLeavesActiveValid() {
        let store = ProfileStore(store: makeDefaults())
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
    @Test("AC-B2: legacy web configuration decodes without a browser preference")
    func legacyBrowserPreference() throws {
        let data = Data("{\"enabled\":true,\"socksPort\":1080,\"proxySuffixes\":[\".internal.example.com\"]}".utf8)
        var configuration = try JSONDecoder().decode(WebForwardsConfiguration.self, from: data)
        #expect(configuration.browser == nil)
        #expect(configuration.browserMode == nil)
        #expect(configuration.browserProfilePath == nil)
        configuration.browser = .chrome
        configuration.browserMode = .separate
        configuration.browserProfilePath = "/tmp/test-browser-profile"
        let decoded = try JSONDecoder().decode(WebForwardsConfiguration.self,
            from: JSONEncoder().encode(configuration))
        #expect(decoded == configuration)
    }

    @Test("AC-1: a stored legacy profile decodes with web forwards absent")
    func legacyWithoutWebForwards() throws {
        let data = Data("""
        {"id":"00000000-0000-0000-0000-000000000001","name":"Legacy",
         "ssoStartUrl":"https://example.awsapps.com/start","ssoRegion":"eu-west-1",
         "accountId":"111122223333","roleName":"Developer","resourceRegion":"eu-central-1",
         "instanceTagKey":"Name","instanceTagValue":"workstation","localPort":8443,
         "remotePort":8443,"connectAction":{"dcvViewer":{}}}
        """.utf8)
        let profile = try JSONDecoder().decode(ConnectionProfile.self, from: data)
        #expect(profile.webForwards == nil)
        #expect(profile.localPort == 8443)
        #expect(profile.resolvedConnectMode == .singleUser)
    }

    @Test("WF-1: optional block defaults and explicit SOCKS disable survive decoding")
    func webForwardsDefaults() throws {
        let defaults = try JSONDecoder().decode(WebForwardsConfiguration.self, from: Data("{}".utf8))
        #expect(defaults.enabled == false)
        #expect(defaults.socksPort == 1080)
        let configuration = WebForwardsConfiguration(enabled: true, socksPort: nil,
            localForwards: [.init(name: "Dashboard", localPort: 4466,
                                  remoteHost: "127.0.0.1", remotePort: 4466, openPath: "/")])
        var profile = ConnectionProfile.example
        profile.webForwards = configuration
        let decoded = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded.webForwards == configuration)
    }

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
