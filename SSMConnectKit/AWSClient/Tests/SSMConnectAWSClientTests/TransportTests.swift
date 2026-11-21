import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SSMConnectAWSClient

/// Every client shares one process-wide ephemeral URLSession. On Linux, URLSessions released
/// while the process keeps working crashed the T5 feasibility helper in FoundationNetworking
/// ("_MultiHandle deallocated with non-zero retain count"); a session per client buys nothing.
@Suite("Transport")
struct TransportTests {
    @Test("Default transports share one ephemeral session")
    func sharedSession() {
        let first = URLSessionTransport()
        let second = URLSessionTransport()
        #expect(first.session === second.session)
    }
}
