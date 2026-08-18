import Foundation
import SSMConnectDomain

/// Persists the last-connected EC2 instance-id per profile, so a connect can detect that the
/// workstation was rebuilt (instance-id changes on every rebuild — stock AMI + cloud-init) and
/// reset any cached tunnel state bound to the terminated instance before establishing (#9, RVL-4).
///
/// **No secrets** — an instance-id is not sensitive (stored in `UserDefaults`, like profiles).
public protocol InstanceIdPersisting: Sendable {
    func lastInstanceId(forProfile id: UUID) -> String?
    func setLastInstanceId(_ instanceId: String, forProfile id: UUID)
}

