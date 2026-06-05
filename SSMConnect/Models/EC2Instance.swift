import Foundation

/// Domain model for the workstation EC2 instance (Phase C).
///
/// SDK-free on purpose: the `AWSEC2` types are mapped into this value in `EC2Service`
/// so the rest of the app (state machine, mocks, tests) never imports the SDK.
struct EC2Instance: Equatable, Sendable {
    let id: String
    let state: State
    /// Private IPv4 address (nil until the instance is running / assigned).
    let privateIpAddress: String?

    /// Lifecycle state, mirroring EC2's `instance-state-name` values (spec §8).
    enum State: String, Sendable {
        case pending
        case running
        case shuttingDown = "shutting-down"
        case stopped
        case stopping
        case terminated
        /// Any value the SDK reports that we don't model explicitly.
        case unknown

        /// Whether the instance is gone / going away and cannot be connected to.
        var isTerminal: Bool { self == .terminated || self == .shuttingDown }
    }
}
