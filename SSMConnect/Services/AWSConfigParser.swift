import Foundation

/// Parses `~/.aws/config` to seed a default connection profile on first launch (G4/G5, spec §12.1).
///
/// Supports the newer **`sso-session`** format (confirmed in the spike, §12.1): a
/// `[profile NAME]` block references a shared `[sso-session NAME]` block via `sso_session = NAME`
/// for the start URL + SSO region, and carries `sso_account_id` / `sso_role_name` / `region`
/// itself. The legacy inline form (`sso_start_url` / `sso_region` directly on the profile) is
/// also honored as a fallback.
struct AWSConfigParser {

    /// An `[sso-session NAME]` block.
    struct SSOSession: Equatable {
        var startUrl: String?
        var region: String?
    }

    /// A `[profile NAME]` (or `[default]`) block.
    struct Profile: Equatable {
        var ssoSession: String?
        var ssoAccountId: String?
        var ssoRoleName: String?
        var region: String?
        // Legacy inline SSO keys.
        var ssoStartUrl: String?
        var ssoRegion: String?
    }

    /// Fully resolved SSO facts for a profile (sso-session block merged in).
    struct ResolvedProfile: Equatable {
        var startUrl: String?
        var ssoRegion: String?
        var accountId: String?
        var roleName: String?
        var resourceRegion: String?
    }

    private(set) var ssoSessions: [String: SSOSession] = [:]
    private(set) var profiles: [String: Profile] = [:]

    /// Parse raw `~/.aws/config` text into sections.
    init(contents: String) {
        var currentSection: (kind: String, name: String)?
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = Self.stripComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("["), line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                currentSection = Self.parseHeader(header)
                if let section = currentSection {
                    switch section.kind {
                    case "sso-session": if ssoSessions[section.name] == nil { ssoSessions[section.name] = SSOSession() }
                    default: if profiles[section.name] == nil { profiles[section.name] = Profile() }
                    }
                }
                continue
            }

            guard let section = currentSection,
                  let (key, value) = Self.parseKeyValue(line) else { continue }
            apply(key: key, value: value, to: section)
        }
    }

    /// Resolve a profile by name, merging its referenced `sso-session` block.
    /// `profileName` is the bare name (e.g. `workstation-prd`); `default` is also accepted.
    func resolvedProfile(named profileName: String) -> ResolvedProfile? {
        guard let profile = profiles[profileName] else { return nil }
        let session = profile.ssoSession.flatMap { ssoSessions[$0] }
        return ResolvedProfile(
            startUrl: session?.startUrl ?? profile.ssoStartUrl,
            ssoRegion: session?.region ?? profile.ssoRegion,
            accountId: profile.ssoAccountId,
            roleName: profile.ssoRoleName,
            resourceRegion: profile.region
        )
    }

    // MARK: - Parsing helpers

    private mutating func apply(key: String, value: String, to section: (kind: String, name: String)) {
        if section.kind == "sso-session" {
            var session = ssoSessions[section.name] ?? SSOSession()
            switch key {
            case "sso_start_url": session.startUrl = value
            case "sso_region": session.region = value
            default: break
            }
            ssoSessions[section.name] = session
        } else {
            var profile = profiles[section.name] ?? Profile()
            switch key {
            case "sso_session": profile.ssoSession = value
            case "sso_account_id": profile.ssoAccountId = value
            case "sso_role_name": profile.ssoRoleName = value
            case "region": profile.region = value
            case "sso_start_url": profile.ssoStartUrl = value
            case "sso_region": profile.ssoRegion = value
            default: break
            }
            profiles[section.name] = profile
        }
    }

    /// Map a section header to `(kind, name)`. `[default]` → `("profile", "default")`,
    /// `[profile foo]` → `("profile", "foo")`, `[sso-session bar]` → `("sso-session", "bar")`.
    private static func parseHeader(_ header: String) -> (kind: String, name: String)? {
        if header == "default" { return ("profile", "default") }
        let parts = header.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return (parts[0], parts[1].trimmingCharacters(in: .whitespaces))
    }

    private static func parseKeyValue(_ line: String) -> (String, String)? {
        guard let eq = line.firstIndex(of: "=") else { return nil }
        let key = line[..<eq].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, value)
    }

    private static func stripComment(_ line: String) -> String {
        // AWS config comments start with # or ; at the start of a (trimmed) token.
        for marker in ["#", ";"] {
            if let range = line.range(of: marker) {
                // Only treat as a comment if it's the line start or preceded by whitespace.
                let before = line[..<range.lowerBound]
                if before.isEmpty || before.last == " " || before.last == "\t" {
                    return String(before)
                }
            }
        }
        return line
    }
}

extension AWSConfigParser {
    /// Convenience: load and parse `~/.aws/config` if it exists.
    static func loadDefault(fileManager: FileManager = .default) -> AWSConfigParser? {
        let url = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/config")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return AWSConfigParser(contents: text)
    }
}
