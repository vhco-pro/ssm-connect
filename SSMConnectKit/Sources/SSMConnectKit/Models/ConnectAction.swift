import Foundation

/// What the app does once the tunnel is up (F-18, §13).
///
/// Profiles retain the DCV Viewer default or explicitly keep only the SSM tunnel.
enum ConnectAction: Codable, Equatable, Sendable {
    /// Launch Amazon DCV Viewer with an auto-login `.dcv` file at `https://127.0.0.1:<localPort>`.
    case dcvViewer
    case tunnelOnly

    var displayName: String {
        switch self {
        case .dcvViewer: "Amazon DCV Viewer"
        case .tunnelOnly: "SSM tunnel only"
        }
    }
}
