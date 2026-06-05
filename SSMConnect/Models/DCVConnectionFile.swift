import Foundation

/// An Amazon DCV **connection file** (`.dcv`, INI format) used to auto-login the DCV Viewer (ADR-8).
///
/// Opening a populated connection file makes DCV Viewer connect and authenticate without manual
/// host/password entry — the only DCV automation hook for credential injection. The password is
/// injected here transiently: the file is written `0600`, opened, and deleted immediately (F-10).
struct DCVConnectionFile: Equatable, Sendable {
    var host: String = "localhost"
    var port: Int
    var user: String = "ec2-user"
    var password: String
    /// DCV web URL path; `/` for a default session.
    var webUrlPath: String = "/"

    /// Temp-file naming so the startup sweep can find orphans left by a crash (ADR-8, §8).
    static let tempFilePrefix = "ssm-connect-"
    static let fileExtension = "dcv"

    /// Renders the INI content DCV Viewer expects.
    func iniContent() -> String {
        """
        [version]
        format=1.0

        [connect]
        host=\(host)
        port=\(port)
        user=\(user)
        password=\(password)
        weburlpath=\(webUrlPath)
        """
    }
}
