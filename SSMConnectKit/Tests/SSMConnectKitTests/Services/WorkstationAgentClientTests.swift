import Testing
import Foundation
@testable import SSMConnectKit

@Suite("WorkstationAgentClient")
struct WorkstationAgentClientTests {
    private static let base = URL(string: "http://127.0.0.1:8444")!

    private static func response(_ code: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: base, statusCode: code, httpVersion: nil, headerFields: nil)!
    }

    @Test("200 -> decoded sessionId/user; token is url-encoded in the form body")
    func ok() async throws {
        let client = WorkstationAgentClient(baseURL: Self.base) { url, body in
            #expect(url.absoluteString == "http://127.0.0.1:8444/ensure-session")
            let s = String(data: body, encoding: .utf8)!
            #expect(s.hasPrefix("authenticationToken="))
            // the token's own '&'/'=' must be percent-encoded so they don't break the form
            #expect(!s.dropFirst("authenticationToken=".count).contains("&"))
            return (Data(#"{"sessionId":"alice","user":"alice"}"#.utf8), Self.response(200))
        }
        let result = try await client.ensureSession(authToken: "https://sts.example/?a=1&b=2")
        #expect(result.user == "alice")
        #expect(result.sessionId == "alice")
    }

    @Test("401 -> unauthorized")
    func unauthorized() async {
        let client = WorkstationAgentClient(baseURL: Self.base) { _, _ in (Data(), Self.response(401)) }
        await #expect(throws: WorkstationAgentClient.AgentError.unauthorized) {
            try await client.ensureSession(authToken: "t")
        }
    }

    @Test("500 -> provisioningFailed")
    func failed() async {
        let client = WorkstationAgentClient(baseURL: Self.base) { _, _ in (Data(), Self.response(500)) }
        await #expect(throws: WorkstationAgentClient.AgentError.provisioningFailed(status: 500)) {
            try await client.ensureSession(authToken: "t")
        }
    }
}
