import Foundation

/// How a profile connects to its DCV workstation (spec CL-04).
///
/// - `singleUser`: the vanilla v1 path — `user=ec2-user` + a Secrets-Manager password against a
///   single-mode (console-session) host. The default, and the always-works fallback. No v2
///   component is involved.
/// - `multiUser`: per-user virtual sessions on a shared host. The client derives the Linux user
///   from the AWS SSO identity, asks the on-box agent to ensure that user's session, and connects
///   with a presigned-identity token instead of a password. A multi-user host is **identity-only**:
///   there is no `ec2-user`/shared fallback (spec MU-00a).
enum ConnectMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case singleUser
    case multiUser

    var id: String { rawValue }

    /// Human-readable label for settings UI.
    var label: String {
        switch self {
        case .singleUser: "Single user (ec2-user + password)"
        case .multiUser: "Multi-user (your AWS identity)"
        }
    }
}
