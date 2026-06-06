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
struct ConnectionProfile: Identifiable, Equatable, Codable, Sendable {
    var id: UUID = UUID()
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

    /// What to launch once the tunnel is up. v1 = DCV Viewer auto-login (F-18, §13).
    var connectAction: ConnectAction = .dcvViewer

    /// Whether the profile has the minimum fields needed to attempt a connection. Used to gate
    /// auto-connect and guide first-launch users (the app ships with NO profile baked in).
    var isConfigured: Bool {
        !ssoStartUrl.isEmpty && !ssoRegion.isEmpty && !accountId.isEmpty
            && !roleName.isEmpty && !resourceRegion.isEmpty
            && !instanceTagKey.isEmpty && !instanceTagValue.isEmpty
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
