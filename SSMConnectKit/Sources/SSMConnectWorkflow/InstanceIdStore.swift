import Foundation
import SSMConnectDomain

/// Persists the last-connected EC2 instance-id per profile, so a connect can detect that the
/// workstation was rebuilt (instance-id changes on every rebuild — stock AMI + cloud-init) and
/// reset any cached tunnel state bound to the terminated instance before establishing (#9, RVL-4).
///
/// **No secrets** — an instance-id is not sensitive (stored in `UserDefaults`, like profiles).
package protocol InstanceIdPersisting: Sendable {
    func lastInstanceId(forProfile id: UUID) -> String?
    func setLastInstanceId(_ instanceId: String, forProfile id: UUID)
}

/// `UserDefaults`-backed `InstanceIdPersisting`. Keyed per profile UUID so multiple workstations
/// each track their own last instance-id.
package struct UserDefaultsInstanceIdStore: InstanceIdPersisting, @unchecked Sendable {
    private let defaults: UserDefaults

    package init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID) -> String { "ssmconnect.lastInstanceId.\(id.uuidString)" }

    package func lastInstanceId(forProfile id: UUID) -> String? { defaults.string(forKey: key(id)) }

    package func setLastInstanceId(_ instanceId: String, forProfile id: UUID) {
        defaults.set(instanceId, forKey: key(id))
    }
}
