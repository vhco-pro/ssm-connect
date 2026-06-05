import Foundation

/// What the app does once the tunnel is up (F-18, §13).
///
/// v1 ships and tests only the DCV Viewer auto-login path (ADR-8). The enum exists so the
/// profile model already carries a "connect action" field; future RDP/VNC/SSH targets are a
/// config-only extension (spec §13) and are intentionally not implemented here.
enum ConnectAction: Codable, Equatable, Sendable {
    /// Launch Amazon DCV Viewer with an auto-login `.dcv` file at `https://localhost:<localPort>`.
    case dcvViewer

    var displayName: String {
        switch self {
        case .dcvViewer: "Amazon DCV Viewer"
        }
    }
}
