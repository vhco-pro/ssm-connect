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
}

extension ConnectionProfile {
    /// Built-in default profile for the factory workstation (spec header / `~/.aws/config`).
    /// Phase G replaces this with `~/.aws/config` seeding; used now so the temporary
    /// "Sign In" menu item (B5) and live integration test (B8) have a working profile.
    static let factoryDefault = ConnectionProfile(
        name: "Example Workstation",
        ssoStartUrl: "https://d-0123456789.awsapps.com/start",
        ssoRegion: "eu-west-1",
        accountId: "111122223333",
        roleName: "AdministratorAccess",
        resourceRegion: "eu-central-1",
        instanceTagKey: "Name",
        instanceTagValue: "factory-workstation",
        secretId: nil,
        localPort: 8443,
        remotePort: 8443
    )
}
