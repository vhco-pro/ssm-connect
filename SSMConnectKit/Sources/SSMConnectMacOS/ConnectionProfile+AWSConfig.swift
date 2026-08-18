import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Building a profile from the user's `~/.aws/config` lives with the parser, not with the domain
/// value: `AWSConfigParser.ResolvedProfile` is a local-filesystem concern, and `SSMConnectDomain`
/// may not depend on persistence (spec §5.2).
public extension ConnectionProfile {

    /// Build a profile from a resolved `~/.aws/config` entry (G4/G5). SSO facts come from config;
    /// the instance tag value + DCV secret id are left for the user to fill (config has no such concept).
    public init(name: String, awsConfig resolved: AWSConfigParser.ResolvedProfile) {
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
