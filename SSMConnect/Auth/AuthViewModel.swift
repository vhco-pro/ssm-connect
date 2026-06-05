import Foundation
import Observation

/// Drives the temporary "Sign In" menu item (B5). This is a Phase B scaffold to validate
/// the auth flow end-to-end; Phase F replaces it with the full `ConnectionStateMachine`.
@MainActor
@Observable
final class AuthViewModel {
    enum Status: Equatable {
        case idle
        case signingIn
        case signedIn(expiry: Date)
        case failed(String)

        /// Title for the menu's primary action button (context-aware, spec §5).
        var actionTitle: String {
            switch self {
            case .idle:       "Connect"
            case .signingIn:  "Connecting…"
            case .signedIn:   "Connected"
            case .failed:     "Retry Connect"
            }
        }

        /// Secondary, non-interactive detail line under the action (nil = hidden).
        var detailLine: String? {
            switch self {
            case .idle, .signingIn:       nil
            case let .signedIn(expiry):   "Signed in · expires \(Self.timeFormatter.string(from: expiry))"
            case let .failed(message):    message
            }
        }

        /// Current connection state used to drive the menu header + menu-bar icon.
        /// Scaffold mapping (Phase B); Phase F's `ConnectionStateMachine` replaces it.
        var connectionState: ConnectionState {
            switch self {
            case .idle:       .disconnected
            case .signingIn:  .authenticating
            case .signedIn:   .connected
            case .failed:     .error
            }
        }

        // 12-hour clock with explicit AM/PM so the expiry time is unambiguous
        // (SSO sessions last ~12 h, so the expiry can be the same wall-clock time).
        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "h:mm a"
            return formatter
        }()
    }

    private(set) var status: Status = .idle

    /// Convenience pass-throughs for the menu view.
    var connectionState: ConnectionState { status.connectionState }
    var actionTitle: String { status.actionTitle }
    var detailLine: String? { status.detailLine }

    private let provider: AuthProviding
    private let profile: ConnectionProfile

    init(provider: AuthProviding = AWSAuthProvider(), profile: ConnectionProfile = .factoryDefault) {
        self.provider = provider
        self.profile = profile
    }

    var isBusy: Bool { status == .signingIn }

    /// Whether the primary action button is tappable (disabled while busy or already connected).
    var actionEnabled: Bool {
        switch status {
        case .idle, .failed:        true
        case .signingIn, .signedIn: false
        }
    }

    func signIn() {
        guard !isBusy else { return }
        status = .signingIn
        Task {
            do {
                let credentials = try await provider.authenticate(profile: profile)
                status = .signedIn(expiry: credentials.expiration)
            } catch {
                status = .failed(error.localizedDescription)
            }
        }
    }
}
