import Foundation

/// Maps a verified AWS caller identity (an STS ARN) to a Linux username.
///
/// This rule MUST stay byte-for-byte identical to the agent's Go rule
/// (`internal/identity` in `vhco-pro/workstation-agent`): the client targets the
/// DCV session named after the user, and the agent's verifier authorizes the
/// connection by the same name. A mismatch would deny a validated user their own
/// session (spec CL-01 / MU-04).
///
/// Security: the mapping is **reject-based, not transform-based**. It refuses any
/// role-session-name that does not already reduce (lowercase + drop the email
/// domain) to a safe, unambiguous Linux username, rather than silently deleting
/// characters or truncating — either of which could merge two distinct identities
/// into the same account. Reserved/system names are refused outright.
enum IdentityMapper {
    enum MappingError: Error, Equatable, LocalizedError {
        case noRoleSessionName
        case unsafeUsername
        case reservedUsername

        var errorDescription: String? {
            switch self {
            case .noRoleSessionName: "Couldn't read your identity from AWS."
            case .unsafeUsername: "Your identity doesn't map to a valid workstation username."
            case .reservedUsername: "Your identity maps to a reserved system username."
            }
        }
    }

    /// Reserved usernames we must never map to (system/service accounts). Mirrors the agent's list.
    static let reserved: Set<String> = [
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
        "proxy", "www-data", "backup", "list", "nobody", "systemd-network", "dbus",
        "sshd", "rpc", "dcv", "dcvsmagent", "ec2-user", "ssm-user", "admin", "ubuntu", "centos",
    ]

    /// Extracts the role-session-name (the segment after the last `/`) from an
    /// assumed-role ARN and maps it to a Linux username, rejecting anything
    /// ambiguous or privileged.
    static func username(fromARN arn: String) throws -> String {
        guard let slash = arn.lastIndex(of: "/") else {
            throw MappingError.noRoleSessionName
        }
        let afterSlash = arn.index(after: slash)
        guard afterSlash < arn.endIndex else {
            throw MappingError.noRoleSessionName
        }
        return try sanitize(String(arn[afterSlash...]))
    }

    /// Reduces a raw SSO username to a Linux username and validates it. Reduction
    /// is minimal and lossless-or-reject: take the local-part before any `@`,
    /// lowercase it; the result must match `^[a-z][a-z0-9_-]{0,31}$` and not be
    /// reserved, else it is REJECTED (never stripped or truncated).
    static func sanitize(_ raw: String) throws -> String {
        var s = raw
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }
        s = s.lowercased()
        guard isSafeName(s) else { throw MappingError.unsafeUsername }
        guard !reserved.contains(s) else { throw MappingError.reservedUsername }
        return s
    }

    /// Matches `^[a-z][a-z0-9_-]{0,31}$`.
    private static func isSafeName(_ s: String) -> Bool {
        let scalars = Array(s.unicodeScalars)
        guard (1...32).contains(scalars.count) else { return false }
        guard isLower(scalars[0]) else { return false }
        for c in scalars where !(isLower(c) || isDigit(c) || c == "-" || c == "_") {
            return false
        }
        return true
    }

    private static func isLower(_ u: Unicode.Scalar) -> Bool { u >= "a" && u <= "z" }
    private static func isDigit(_ u: Unicode.Scalar) -> Bool { u >= "0" && u <= "9" }
}
