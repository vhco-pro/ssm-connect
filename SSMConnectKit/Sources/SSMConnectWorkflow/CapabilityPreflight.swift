import Foundation
import SSMConnectDomain

/// A capability an action cannot work without (AC-25). The core checks the ones an action needs
/// before any AWS call, process launch or configuration write, and refuses the action with a
/// message naming the missing one; it never switches to another connection mode. DCV Viewer is
/// not one: a desktop connection without it keeps its tunnel and warns.
package enum Capability: String, Sendable, CaseIterable {
    /// Every action: SSM tunnels, SSH and the editor all run through it.
    case sessionManagerPlugin
    /// Web forwards and the editor.
    case openSSH
    /// The editor.
    case visualStudioCode
    /// Managed browsing.
    case browser
}

package enum CapabilityError: LocalizedError, Equatable {
    case missing(Capability)

    package var errorDescription: String? {
        switch self {
        case .missing(.sessionManagerPlugin):
            "The Session Manager plugin is required for this action and was not found. Reinstall SSM Connect, then try again."
        case .missing(.openSSH):
            "OpenSSH is required for this action and was not found. Install the OpenSSH client, then try again."
        case .missing(.visualStudioCode):
            "Visual Studio Code is required for this action and was not found. Install it, then try again."
        case .missing(.browser):
            "A supported browser is required for managed browsing and was not found. Install Chrome or Zen at a supported version, then try again."
        }
    }
}
