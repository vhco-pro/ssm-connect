import Foundation
import SSMConnectWorkflow
import SSMConnectDomain

/// `UserDefaults`-backed `InstanceIdPersisting`. Keyed per profile UUID so multiple workstations
/// each track their own last instance-id.
public struct UserDefaultsInstanceIdStore: InstanceIdPersisting, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(_ id: UUID) -> String { "ssmconnect.lastInstanceId.\(id.uuidString)" }

    public func lastInstanceId(forProfile id: UUID) -> String? { defaults.string(forKey: key(id)) }

    public func setLastInstanceId(_ instanceId: String, forProfile id: UUID) {
        defaults.set(instanceId, forKey: key(id))
    }
}
