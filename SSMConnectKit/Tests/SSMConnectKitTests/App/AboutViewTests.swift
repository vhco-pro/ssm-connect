import Testing
@testable import SSMConnectKit

@Suite("About app metadata")
struct AboutViewTests {
    @Test("About shows the bundle's release version and build number")
    func releaseMetadata() {
        let info = AboutAppInfo(dictionary: [
            "CFBundleDisplayName": "SSM Connect",
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
        ])
        #expect(info.name == "SSM Connect")
        #expect(info.versionLabel == "Version 1.2.3 (Build 42)")
    }

    @Test("About handles missing version metadata without inventing a release")
    func missingMetadata() {
        let info = AboutAppInfo(dictionary: [:])
        #expect(info.name == "SSM Connect")
        #expect(info.versionLabel == "Development build")
    }

    @Test("About supports version-only and build-only metadata")
    func partialMetadata() {
        #expect(AboutAppInfo(dictionary: ["CFBundleShortVersionString": "2.0"]).versionLabel == "Version 2.0")
        #expect(AboutAppInfo(dictionary: ["CFBundleVersion": "99"]).versionLabel == "Build 99")
    }

    @Test("About ignores blank fields and falls back to the bundle name")
    func blankMetadata() {
        let info = AboutAppInfo(dictionary: ["CFBundleDisplayName": "  ", "CFBundleName": "SSMConnect",
                                            "CFBundleShortVersionString": "\n", "CFBundleVersion": " 7 "])
        #expect(info.name == "SSMConnect")
        #expect(info.versionLabel == "Build 7")
    }

    @Test("About and log use distinct window identifiers")
    func distinctWindows() {
        #expect(SSMConnectWindow.about != SSMConnectWindow.log)
    }
}