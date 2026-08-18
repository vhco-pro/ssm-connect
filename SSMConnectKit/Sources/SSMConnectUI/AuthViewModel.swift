import Foundation
import Observation
import SSMConnectDomain
import SSMConnectWorkflow
import SSMConnectMacOS

/// Drives the temporary "Sign In" menu item (B5). This is a Phase B scaffold to validate
/// the auth flow end-to-end; Phase F replaces it with the full `ConnectionStateMachine`.
@MainActor
@Observable
public final class AuthViewModel {
    public enum Status: Equatable {
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
    public var connectionState: ConnectionState { status.connectionState }
    public var actionTitle: String { status.actionTitle }
    public var detailLine: String? { status.detailLine }

    private let provider: AuthProviding
    private let profile: ConnectionProfile

    /// The provider is injected rather than defaulted to `AWSAuthProvider()`: a view model
    /// constructing an AWS adapter would make the UI target depend on the AWS SDK, which §5.2
    /// rules out. The composition root supplies it, as it does for the state machine.
    public init(provider: AuthProviding, profile: ConnectionProfile = .template) {
        self.provider = provider
        self.profile = profile
    }

    public var isBusy: Bool { status == .signingIn }

    /// Whether the primary action button is tappable (disabled while busy or already connected).
    public var actionEnabled: Bool {
        switch status {
        case .idle, .failed:        true
        case .signingIn, .signedIn: false
        }
    }

    public func signIn() {
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
