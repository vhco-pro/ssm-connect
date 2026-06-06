import Foundation
@testable import SSMConnect

extension ConnectionProfile {
    /// A fully-populated example profile for tests. The app binary intentionally ships **no**
    /// concrete AWS environment (see `ConnectionProfile.template`); these example values live only
    /// in the test target.
    static var example: ConnectionProfile {
        ConnectionProfile(
            name: "Example Workstation",
            ssoStartUrl: "https://d-0123456789.awsapps.com/start",
            ssoRegion: "eu-west-1",
            accountId: "111122223333",
            roleName: "AdministratorAccess",
            resourceRegion: "eu-central-1",
            instanceTagKey: "Name",
            instanceTagValue: "example-workstation",
            secretId: "ec2/workstation-dcv-password",
            localPort: 8443,
            remotePort: 8443
        )
    }
}
