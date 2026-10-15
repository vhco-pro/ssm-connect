import Foundation

/// Pure, SwiftUI-free validation decisions for the profile editor's region fields, so the
/// Save-gate and inline-error behaviour can be unit-tested without rendering a view.
enum ProfileEditorValidation {
    static func normalizedProxySuffixes(_ values: [String]) -> [String] {
        values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }

    static func webForwardsError(_ configuration: WebForwardsConfiguration) -> String? {
        let ports = configuration.localForwards.map(\.localPort) + (configuration.socksPort.map { [$0] } ?? [])
        guard ports.allSatisfy({ (1...65535).contains($0) }),
              configuration.localForwards.allSatisfy({ (1...65535).contains($0.remotePort) }) else {
            return "Ports must be between 1 and 65535."
        }
        guard Set(ports).count == ports.count else { return "Local ports must be unique, including the SOCKS port." }
        guard !ports.isEmpty else { return "Configure a SOCKS port or at least one local forward." }
        if let user = configuration.sshUser, !user.isEmpty,
           !safeHost(user) { return "SSH user contains unsupported characters." }
        for suffix in configuration.proxySuffixes {
            guard suffix.hasPrefix("."), suffix.count > 1,
                  safeHost(suffix), !suffix.contains(".."), !suffix.hasSuffix(".") else {
                return "Proxy suffixes must start with a dot and contain a domain name."
            }
        }
        if !configuration.proxySuffixes.isEmpty, configuration.socksPort == nil {
            return "Proxy suffixes require a SOCKS port."
        }
        for forward in configuration.localForwards {
            guard !forward.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Each local forward needs a name."
            }
            guard safeHost(forward.remoteHost) else { return "Remote hosts must be hostnames or IPv4 addresses." }
            if let path = forward.openPath, !path.isEmpty,
               !path.hasPrefix("/") || path.contains(where: { $0.isWhitespace || $0.isNewline }) {
                return "Open paths must start with / and contain no whitespace."
            }
        }
        return nil
    }

    static func safeHost(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("-") && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    /// The display decision for a single region field.
    struct RegionFieldState: Equatable {
        /// Whether the field's (trimmed) value is an acceptable AWS region. Drives the Save gate.
        var isValid: Bool
        /// Whether to show an inline field-level error. True only when the field is non-empty but
        /// invalid, so a fresh, empty form is not noisy.
        var showError: Bool
    }

    /// Evaluate a raw region field value (as typed, possibly with surrounding whitespace).
    static func regionState(_ raw: String) -> RegionFieldState {
        let trimmed = AWSRegion.normalize(raw)
        let valid = AWSRegion.isValid(trimmed)
        return RegionFieldState(isValid: valid, showError: !trimmed.isEmpty && !valid)
    }
}
