import Foundation
import SSMConnectDomain

/// Key lifecycle events surfaced as macOS notifications (H4, F-20).
public enum NotificationEvent: Equatable, Sendable {
    case connected
    case stopped
    case reconnecting
    case signInRequired

    /// The name this event travels under in the conformance fixtures.
    ///
    /// Contract, not a detail: both clients emit the same sequence for the same run, and
    /// `expect.calls` asserts these strings. Spelled out rather than derived from the case name so
    /// renaming a case cannot silently change the wire vocabulary. Mirrors .NET's
    /// `NotificationNames.Wire`.
    public var wireName: String {
        switch self {
        case .connected:      "connected"
        case .stopped:        "stopped"
        case .reconnecting:   "reconnecting"
        case .signInRequired: "signInRequired"
        }
    }

    public var title: String {
        switch self {
        case .connected: "Connected to workstation"
        case .stopped: "Workstation stopped"
        case .reconnecting: "Tunnel disconnected — reconnecting…"
        case .signInRequired: "SSO login required"
        }
    }

    public var body: String {
        switch self {
        case .connected: "Your SSM tunnel is up and DCV is launching."
        case .stopped: "The workstation instance has been stopped."
        case .reconnecting: "The tunnel dropped. Attempting to reconnect…"
        case .signInRequired: "Your AWS SSO session expired. Re-authenticating…"
        }
    }
}

