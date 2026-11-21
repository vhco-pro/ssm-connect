import SwiftUI

extension ConnectionState {
    // Spec §5: Color per state
    package var color: Color {
        switch self {
        case .disconnected:   .gray
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: .yellow
        case .connected:      .green
        case .error:          .red
        }
    }
}
