import Foundation

/// An Amazon DCV **connection file** (`.dcv`, INI format) used to auto-login the DCV Viewer (ADR-8).
///
/// Opening a populated connection file makes DCV Viewer connect and authenticate without manual
/// host/password entry — the only DCV automation hook for credential injection. The secret is
/// injected here transiently: the file is written `0600`, opened, and deleted immediately (F-10).
///
/// Two auth modes are supported:
/// - **Vanilla (single-user):** `password=` from Secrets Manager, `user=ec2-user`. Unchanged from v1.
/// - **Multi-user:** `authtoken=` (a presigned-identity token) + `sessionid=` targeting the user's
///   own virtual session. No password. The native client supports both `authtoken` and `sessionid`
///   in the `[connect]` section.
struct DCVConnectionFile: Equatable, Sendable {
    /// IPv4 loopback (not `localhost`): the SSM port-forward binds IPv4 `127.0.0.1` only, while
    /// `localhost` resolves to IPv6 `::1` first on macOS — the DCV Viewer then connects to `::1`,
    /// finds no listener, and fails with "endpoint is unreachable" (see docs/specs/bug-ipv6-localhost-*).
    var host: String = "127.0.0.1"
    var port: Int
    var user: String = "ec2-user"
    /// Vanilla auth: Secrets-Manager password. `nil` in multi-user mode.
    var password: String?
    /// Multi-user auth: presigned-identity token. `nil` in vanilla mode.
    var authToken: String?
    /// Target DCV session id (the user's own virtual session). `nil` for the default session.
    var sessionId: String?
    /// DCV web URL path; `/` for a default session.
    var webUrlPath: String = "/"

    /// Temp-file naming so the startup sweep can find orphans left by a crash (ADR-8, §8).
    static let tempFilePrefix = "ssm-connect-"
    static let fileExtension = "dcv"

    /// Vanilla (single-user) connection: `user` + Secrets-Manager `password`.
    static func vanilla(host: String = "127.0.0.1", port: Int, user: String = "ec2-user", password: String) -> DCVConnectionFile {
        DCVConnectionFile(host: host, port: port, user: user, password: password)
    }

    /// Multi-user connection: `user`'s own `sessionId`, authorized by a presigned-identity `authToken`.
    static func multiUser(host: String = "127.0.0.1", port: Int, user: String, sessionId: String, authToken: String) -> DCVConnectionFile {
        DCVConnectionFile(host: host, port: port, user: user, password: nil, authToken: authToken, sessionId: sessionId)
    }

    /// Renders the INI content DCV Viewer expects. Emits only the fields relevant to the active
    /// auth mode (token fields when present, otherwise the password field).
    func iniContent() -> String {
        var lines = [
            "[version]",
            "format=1.0",
            "",
            "[connect]",
            "host=\(host)",
            "port=\(port)",
            "user=\(user)",
        ]
        if let sessionId { lines.append("sessionid=\(sessionId)") }
        if let authToken { lines.append("authtoken=\(authToken)") }
        if let password { lines.append("password=\(password)") }
        lines.append("weburlpath=\(webUrlPath)")
        return lines.joined(separator: "\n")
    }
}
