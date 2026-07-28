import Foundation

/// Ensures DCV Viewer preferences that must be set *before* launch. Today: HiDPI (Retina). The DCV
/// Viewer streams at 1x by default, so a Retina Mac looks soft; we set `enable-high-pixel-density`
/// in the Viewer's GSettings (a GLib **keyfile** backend, not macOS `defaults`) so it requests the
/// 2x physical resolution. Pairs with the server-side scale watcher that renders the desktop at
/// 200%. See docs/specs/dcv-viewer-hidpi.spec.md (CL-06 / workstation §12.9 / MU-15).
protocol DCVViewerConfiguring: Sendable {
    /// Best-effort; MUST NOT throw or block the connect. `backingScale` is the client display's
    /// scale factor (every M-series Mac is 2).
    func ensurePreferredSettings(backingScale: CGFloat)
}

/// Default `DCVViewerConfiguring`: edits the DCV Viewer's GLib keyfile
/// (`~/.config/glib-2.0/settings/keyfile`). Only enables HiDPI on a 2x display, and only when the
/// key is **unset** — a user who turned it off in the Viewer is respected. Other content preserved.
struct GLibKeyfileDCVViewerConfigurator: DCVViewerConfiguring {
    static let group = "com/nicesoftware/DcvViewer"
    static let key = "enable-high-pixel-density"

    /// GLib's keyfile-backend path. Overridable for tests.
    var keyfileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/glib-2.0/settings/keyfile")

    func ensurePreferredSettings(backingScale: CGFloat) {
        guard backingScale >= 2 else { return }                       // HDPI-2: Retina only
        let existing = (try? String(contentsOf: keyfileURL, encoding: .utf8)) ?? ""
        guard let updated = Self.enableHiDPIIfAbsent(in: existing) else { return }  // HDPI-3: no-op if set
        do {                                                          // HDPI-4: best-effort
            try FileManager.default.createDirectory(at: keyfileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try updated.write(to: keyfileURL, atomically: true, encoding: .utf8)
        } catch { /* swallow — never fail/slow the connect */ }
    }

    /// Merge `enable-high-pixel-density=true` under `[com/nicesoftware/DcvViewer]`, preserving all
    /// other content (HDPI-5). Returns nil (no write) if the key is already present under the group,
    /// so an explicit user choice — `true` or `false` — is never overridden (HDPI-3).
    static func enableHiDPIIfAbsent(in content: String) -> String? {
        let header = "[\(group)]"
        var lines = content.isEmpty ? [] : content.components(separatedBy: "\n")
        guard let groupIdx = lines.firstIndex(of: header) else {      // group absent -> append it
            if let last = lines.last, !last.isEmpty { lines.append("") }
            lines.append(contentsOf: [header, "\(key)=true"])
            return normalize(lines)
        }
        var i = groupIdx + 1                                          // scan the group body
        while i < lines.count && !lines[i].hasPrefix("[") {
            if lines[i].hasPrefix("\(key)=") { return nil }           // already set -> respect it
            i += 1
        }
        lines.insert("\(key)=true", at: groupIdx + 1)
        return normalize(lines)
    }

    private static func normalize(_ lines: [String]) -> String {
        var out = lines
        while out.last == "" { out.removeLast() }                     // no trailing blank lines
        return out.joined(separator: "\n") + "\n"
    }
}
