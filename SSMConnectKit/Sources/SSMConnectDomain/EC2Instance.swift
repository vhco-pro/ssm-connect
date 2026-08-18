import Foundation

/// Domain model for the workstation EC2 instance (Phase C).
///
/// SDK-free on purpose: the `AWSEC2` types are mapped into this value in `EC2Service`
/// so the rest of the app (state machine, mocks, tests) never imports the SDK.
public struct EC2Instance: Equatable, Sendable {
    public init(id: String, state: State, privateIpAddress: String? = nil) {
        self.id = id
        self.state = state
        self.privateIpAddress = privateIpAddress
    }

    public let id: String
    public let state: State
    /// Private IPv4 address (nil until the instance is running / assigned).
    public let privateIpAddress: String?

    /// Lifecycle state, mirroring EC2's `instance-state-name` values (spec §8).
    public enum State: String, Sendable {
        case pending
        case running
        case shuttingDown = "shutting-down"
        case stopped
        case stopping
        case terminated
        /// Any value the SDK reports that we don't model explicitly.
        case unknown

        /// Whether the instance is gone / going away and cannot be connected to.
        public var isTerminal: Bool { self == .terminated || self == .shuttingDown }
    }
}
