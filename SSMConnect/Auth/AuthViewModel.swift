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

        var menuTitle: String {
            switch self {
            case .idle:                   "Sign In"
            case .signingIn:              "Signing In…"
            case let .signedIn(expiry):   "Signed In · expires \(Self.timeFormatter.string(from: expiry))"
            case let .failed(message):    "Sign-In Failed: \(message)"
            }
        }

        private static let timeFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return formatter
        }()
    }

    private(set) var status: Status = .idle

    private let provider: AuthProviding
    private let profile: ConnectionProfile

    init(provider: AuthProviding = AWSAuthProvider(), profile: ConnectionProfile = .factoryDefault) {
        self.provider = provider
        self.profile = profile
    }

    var isBusy: Bool { status == .signingIn }

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
