import Testing
@testable import SSMConnect

// Task A7, ADR-P2 — Swift Testing placeholder test for ConnectionState
// Verifies: SSM Connect Plan, Criterion: "ConnectionState has 8 cases"
@Suite("ConnectionState")
struct ConnectionStateTests {

    @Test("ConnectionState enum has exactly 8 cases per spec §5")
    func stateHasEightCases() {
        // Task A4: disconnected, authenticating, resolving, starting,
        //          waitingForSSM, tunneling, connected, error
        #expect(ConnectionState.allCases.count == 8)
    }

    @Test("Every state provides a non-empty SF Symbol name")
    func allStatesHaveSFSymbols() {
        for state in ConnectionState.allCases {
            #expect(!state.sfSymbol.isEmpty, "State \(state) has no SF Symbol")
        }
    }

    @Test("Every state provides a non-empty tooltip")
    func allStatesHaveTooltips() {
        for state in ConnectionState.allCases {
            #expect(!state.tooltip.isEmpty, "State \(state) has no tooltip")
        }
    }

    @Test("Connected state is green, error state is red, disconnected is gray")
    func keyStateColors() {
        #expect(ConnectionState.connected.color == .green)
        #expect(ConnectionState.error.color == .red)
        #expect(ConnectionState.disconnected.color == .gray)
    }

    @Test("Transitioning states are the 5 in-progress states")
    func transitioningStates() {
        let transitioning = ConnectionState.allCases.filter(\.isTransitioning)
        #expect(transitioning.count == 5)
        #expect(ConnectionState.authenticating.isTransitioning)
        #expect(ConnectionState.resolving.isTransitioning)
        #expect(ConnectionState.starting.isTransitioning)
        #expect(ConnectionState.waitingForSSM.isTransitioning)
        #expect(ConnectionState.tunneling.isTransitioning)
    }
}
