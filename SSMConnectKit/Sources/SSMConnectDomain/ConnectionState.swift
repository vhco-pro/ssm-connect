import Foundation

// Task A4 — 8-state connection lifecycle enum per spec §5.
//
// This is a domain value and nothing else. Its presentation — SF Symbol, colour, tooltip — lives
// in `App/ConnectionState+Presentation.swift`, because a domain state enum cannot own how it is
// drawn (spec §5.2, MR-02): the `Color` property is what pulled SwiftUI into the workflow.
// The raw values are the wire strings used by `contracts/state-machine.schema.json`.
// `CaseIterable` supports exhaustive iteration (e.g. the placeholder menu, tests).
public enum ConnectionState: String, CaseIterable, Sendable {
    case disconnected    // F-01: idle / not connected
    case authenticating  // F-04, F-05: SSO login in progress
    case resolving       // F-06: DescribeInstances by tag
    case starting        // F-07: StartInstances + polling
    case waitingForSSM   // F-08: DescribeInstanceInformation polling
    case tunneling       // F-09: StartSession + plugin launch
    case connected       // F-09, F-10: tunnel active
    case error           // any failure state

    /// Whether this state represents an in-progress (transitional) phase.
    public var isTransitioning: Bool {
        switch self {
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: true
        case .disconnected, .connected, .error: false
        }
    }
}
