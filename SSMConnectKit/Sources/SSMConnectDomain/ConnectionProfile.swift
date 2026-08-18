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
    public init(
        id: UUID = UUID(),
        name: String,
        ssoStartUrl: String,
        ssoRegion: String,
        accountId: String,
        roleName: String,
        resourceRegion: String,
        instanceTagKey: String,
        instanceTagValue: String,
        secretId: String? = nil,
        localPort: Int,
        remotePort: Int,
        connectAction: ConnectAction = .dcvViewer,
        connectMode: ConnectMode? = nil,
        agentRemotePort: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.ssoStartUrl = ssoStartUrl
        self.ssoRegion = ssoRegion
        self.accountId = accountId
        self.roleName = roleName
        self.resourceRegion = resourceRegion
        self.instanceTagKey = instanceTagKey
        self.instanceTagValue = instanceTagValue
        self.secretId = secretId
        self.localPort = localPort
        self.remotePort = remotePort
        self.connectAction = connectAction
        self.connectMode = connectMode
        self.agentRemotePort = agentRemotePort
    }

    public var id: UUID = UUID()
    public var name: String

    // MARK: SSO / authentication (Phase B)

    /// AWS SSO start URL, e.g. `https://d-xxxx.awsapps.com/start`.
    public var ssoStartUrl: String
    /// SSO/OIDC region for `SSOOIDC.*` and `SSO.GetRoleCredentials` (e.g. `eu-west-1`).
    /// Distinct from `resourceRegion` (B4, spec §F-04).
    public var ssoRegion: String
    public var accountId: String
    public var roleName: String

    // MARK: Resource operations (Phases C–E)

    /// Region for EC2/SSM/Secrets operations (e.g. `eu-central-1`).
    public var resourceRegion: String
    public var instanceTagKey: String
    public var instanceTagValue: String
    /// Secrets Manager secret id for the DCV password (optional, F-11).
    public var secretId: String?

    // MARK: Tunnel (Phase D)

    public var localPort: Int
    /// Remote port forwarded over the tunnel (DCV default 8443).
    public var remotePort: Int

    // MARK: Connect action (Phase E/G)

    /// What to launch once the tunnel is up. v1 = DCV Viewer auto-login (F-18, §13).
    public var connectAction: ConnectAction = .dcvViewer

    // MARK: Multi-user (Phase F)

    /// Connect mode. `nil` (legacy profiles / default) is treated as `.singleUser`, so existing
    /// profiles and stored data are unaffected. `.multiUser` switches to per-user virtual sessions
    /// authenticated by a presigned-identity token (no password) — see spec MU-00a / CL-04.
    public var connectMode: ConnectMode? = nil
    /// Port the on-box agent listens on (`/ensure-session` + token verifier), forwarded over a second
    /// SSM tunnel in multi-user mode. `nil` → 8444.
    public var agentRemotePort: Int? = nil

    /// Resolved connect mode — legacy/`nil` maps to `.singleUser` (vanilla, the default).
    public var resolvedConnectMode: ConnectMode { connectMode ?? .singleUser }
    /// Resolved agent port (`nil` → 8444).
    public var resolvedAgentRemotePort: Int { agentRemotePort ?? 8444 }

    /// Whether the profile has the minimum fields needed to attempt a connection. Used to gate
    /// auto-connect and guide first-launch users (the app ships with NO profile baked in).
    public var isConfigured: Bool {
        !ssoStartUrl.isEmpty && AWSRegion.isValid(ssoRegion) && !accountId.isEmpty
            && !roleName.isEmpty && AWSRegion.isValid(resourceRegion)
            && !instanceTagKey.isEmpty && !instanceTagValue.isEmpty
    }
}

public extension ConnectionProfile {
    /// A neutral, empty profile the user fills in (nothing about any AWS environment is hardcoded
    /// in the app — F-18, ADR-5). Ports default to DCV's 8443. The instance tag value and secret
    /// id are blank because `~/.aws/config` doesn't carry them; the user supplies them in Settings.
    public static var template: ConnectionProfile {
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

}
