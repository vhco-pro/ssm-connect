import Foundation

/// A named connection profile — the central config model for the app (F-18, ADR-5).
///
/// Nothing about a connection is hardcoded: account, SSO start URL, SSO region,
/// resource region, instance tag, secret id, and ports all live here so the app can
/// drive any SSM-reachable EC2 workstation. The factory workstation ships as the
/// default profile; single-workstation users only ever see this one.
///
/// Stored in `UserDefaults` (no secrets — NF-01). Later phases add the connect action
/// (Phase E) and profile management UI/seeding (Phase G).
public struct ConnectionProfile: Identifiable, Equatable, Codable, Sendable {
    public var id: UUID = UUID()
    var name: String

    // MARK: SSO / authentication (Phase B)

    /// AWS SSO start URL, e.g. `https://d-xxxx.awsapps.com/start`.
    var ssoStartUrl: String
    /// SSO/OIDC region for `SSOOIDC.*` and `SSO.GetRoleCredentials` (e.g. `eu-west-1`).
    /// Distinct from `resourceRegion` (B4, spec §F-04).
    var ssoRegion: String
    var accountId: String
    var roleName: String

    // MARK: Resource operations (Phases C–E)

    /// Region for EC2/SSM/Secrets operations (e.g. `eu-central-1`).
    var resourceRegion: String
    var instanceTagKey: String
    var instanceTagValue: String
    /// Secrets Manager secret id for the DCV password (optional, F-11).
    var secretId: String?

    // MARK: Tunnel (Phase D)

    var localPort: Int
    /// Remote port forwarded over the tunnel (DCV default 8443).
    var remotePort: Int

    // MARK: Connect action (Phase E/G)

    /// What to launch once the tunnel is up; existing profiles default to DCV Viewer.
    var connectAction: ConnectAction = .dcvViewer

    // MARK: Multi-user (Phase F)

    /// Connect mode. `nil` (legacy profiles / default) is treated as `.singleUser`, so existing
    /// profiles and stored data are unaffected. `.multiUser` switches to per-user virtual sessions
    /// authenticated by a presigned-identity token (no password) — see spec MU-00a / CL-04.
    var connectMode: ConnectMode? = nil
    /// Port the on-box agent listens on (`/ensure-session` + token verifier), forwarded over a second
    /// SSM tunnel in multi-user mode. `nil` → 8444.
    var agentRemotePort: Int? = nil
    var webForwards: WebForwardsConfiguration? = nil
    var remoteDevelopment: RemoteDevelopmentConfiguration? = nil

    /// Resolved connect mode — legacy/`nil` maps to `.singleUser` (vanilla, the default).
    var resolvedConnectMode: ConnectMode { connectMode ?? .singleUser }
    /// Resolved agent port (`nil` → 8444).
    var resolvedAgentRemotePort: Int { agentRemotePort ?? 8444 }

    /// Whether the profile has the minimum fields needed to attempt a connection. Used to gate
    /// auto-connect and guide first-launch users (the app ships with NO profile baked in).
    var isConfigured: Bool {
        !ssoStartUrl.isEmpty && AWSRegion.isValid(ssoRegion) && !accountId.isEmpty
            && !roleName.isEmpty && AWSRegion.isValid(resourceRegion)
            && !instanceTagKey.isEmpty && !instanceTagValue.isEmpty
    }
}

struct RemoteDevelopmentConfiguration: Equatable, Codable, Sendable {
    var enabled = false
    var folder: String? = nil
}

struct WebForwardsConfiguration: Equatable, Codable, Sendable {
    var enabled: Bool = false
    var sshUser: String? = nil
    var socksPort: Int? = 1080
    var proxySuffixes: [String] = []
    var localForwards: [LocalForward] = []
    var browser: ManagedBrowserChoice? = nil
    var browserMode: BrowserMode? = nil
    var browserProfilePath: String? = nil

    struct LocalForward: Identifiable, Equatable, Codable, Sendable {
        var id: Int { localPort }
        var name: String
        var localPort: Int
        var remoteHost: String
        var remotePort: Int
        var openPath: String? = nil
        var portableOptions: [String: ProfileValue] = [:]

        enum CodingKeys: String, CodingKey {
            case name, localPort, remoteHost, remotePort, openPath, portableOptions
        }
    }

    init(enabled: Bool = false, sshUser: String? = nil, socksPort: Int? = 1080,
            proxySuffixes: [String] = [], localForwards: [LocalForward] = [], browser: ManagedBrowserChoice? = nil,
            browserMode: BrowserMode? = nil, browserProfilePath: String? = nil) {
        self.enabled = enabled
        self.sshUser = sshUser
        self.socksPort = socksPort
        self.proxySuffixes = proxySuffixes
        self.localForwards = localForwards
        self.browser = browser
        self.browserMode = browserMode
        self.browserProfilePath = browserProfilePath
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, sshUser, socksPort, proxySuffixes, localForwards, browser, browserMode, browserProfilePath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        sshUser = try values.decodeIfPresent(String.self, forKey: .sshUser)
        socksPort = values.contains(.socksPort)
            ? try values.decodeIfPresent(Int.self, forKey: .socksPort) : 1080
        proxySuffixes = try values.decodeIfPresent([String].self, forKey: .proxySuffixes) ?? []
        localForwards = try values.decodeIfPresent([LocalForward].self, forKey: .localForwards) ?? []
        browser = try values.decodeIfPresent(ManagedBrowserChoice.self, forKey: .browser)
        browserMode = try values.decodeIfPresent(BrowserMode.self, forKey: .browserMode)
        browserProfilePath = try values.decodeIfPresent(String.self, forKey: .browserProfilePath)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encodeIfPresent(sshUser, forKey: .sshUser)
        try values.encode(socksPort, forKey: .socksPort)
        try values.encode(proxySuffixes, forKey: .proxySuffixes)
        try values.encode(localForwards, forKey: .localForwards)
        try values.encodeIfPresent(browser, forKey: .browser)
        try values.encodeIfPresent(browserMode, forKey: .browserMode)
        try values.encodeIfPresent(browserProfilePath, forKey: .browserProfilePath)
    }
}

extension WebForwardsConfiguration.LocalForward {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        localPort = try values.decode(Int.self, forKey: .localPort)
        remoteHost = try values.decode(String.self, forKey: .remoteHost)
        remotePort = try values.decode(Int.self, forKey: .remotePort)
        openPath = try values.decodeIfPresent(String.self, forKey: .openPath)
        portableOptions = try values.decodeIfPresent([String: ProfileValue].self, forKey: .portableOptions) ?? [:]
    }
}

enum BrowserMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case existing, separate
    var id: String { rawValue }
    var name: String { self == .existing ? "Use My Browser" : "Separate Browser" }
}

enum ManagedBrowserChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic, chrome, edge, firefox, zen

    var id: String { rawValue }
    var name: String {
        switch self {
        case .automatic: "Automatic"
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .firefox: "Firefox"
        case .zen: "Zen"
        }
    }
}

extension ConnectionProfile {
    /// A neutral, empty profile the user fills in (nothing about any AWS environment is hardcoded
    /// in the app — F-18, ADR-5). Ports default to DCV's 8443. The instance tag value and secret
    /// id are blank because `~/.aws/config` doesn't carry them; the user supplies them in Settings.
    static var template: ConnectionProfile {
        ConnectionProfile(
            name: "New Workstation",
            ssoStartUrl: "",
            ssoRegion: "",
            accountId: "",
            roleName: "",
            resourceRegion: "",
            instanceTagKey: "Name",
            instanceTagValue: "",
            secretId: nil,
            localPort: 8443,
            remotePort: 8443
        )
    }

    /// Build a profile from a resolved `~/.aws/config` entry (G4/G5). SSO facts come from config;
    /// the instance tag value + DCV secret id are left for the user to fill (config has no such concept).
    init(name: String, awsConfig resolved: AWSConfigParser.ResolvedProfile) {
        self.init(
            name: name,
            ssoStartUrl: resolved.startUrl ?? "",
            ssoRegion: resolved.ssoRegion ?? "",
            accountId: resolved.accountId ?? "",
            roleName: resolved.roleName ?? "",
            resourceRegion: resolved.resourceRegion ?? "",
            instanceTagKey: "Name",
            instanceTagValue: "",
            secretId: nil,
            localPort: 8443,
            remotePort: 8443
        )
    }
}
