import Foundation

/// Maps a verified AWS caller identity (an STS ARN) to a Linux username.
///
/// This rule MUST stay byte-for-byte identical to the agent's rule
/// (`internal/identity` in `vhco-pro/workstation-agent`): the client targets the
/// DCV session named after the user, and the agent's verifier authorizes the
/// connection by the same name. A mismatch would deny a validated user their own
/// session (spec CL-01 / MU-04).
enum IdentityMapper {
    enum MappingError: Error, Equatable {
        case noRoleSessionName
        case emptyAfterSanitize
    }

    /// Extracts the role-session-name (the segment after the last `/`) from an
    /// assumed-role ARN and sanitizes it into a Linux username.
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

    /// Org-agnostic default rule (no environment-specific assumptions baked in):
    /// take the local-part before any `@`, lowercase it, keep only `[a-z0-9_-]`,
    /// and trim to 32 characters. Organisations needing a different rule supply
    /// it as configuration rather than changing this default.
    static func sanitize(_ raw: String) throws -> String {
        var s = raw
        if let at = s.firstIndex(of: "@") {
            s = String(s[..<at])
        }
        s = s.lowercased()
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter(isAllowed)))
        guard !s.isEmpty else { throw MappingError.emptyAfterSanitize }
        if s.count > 32 {
            s = String(s.prefix(32))
        }
        return s
    }

    private static func isAllowed(_ u: Unicode.Scalar) -> Bool {
        (u >= "a" && u <= "z") || (u >= "0" && u <= "9") || u == "-" || u == "_"
    }
}
