import Foundation

/// The VS Code remote folder rule shared by profile validation and the remote-development
/// launcher: a folder is an absolute remote path with no newline or NUL, opened as a
/// `vscode-remote://ssh-remote+<alias><folder>` URI.
package enum RemoteFolder {
    /// The folder URI for an SSH host alias, or nil when the folder breaks the rule.
    package static func uri(alias: String, folder: String) -> String? {
        guard folder.hasPrefix("/"), !folder.contains(where: \ .isNewline), !folder.contains("\0") else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "vscode-remote"
        components.host = "ssh-remote+" + alias
        components.path = folder
        return components.url?.absoluteString
    }
}
