import Foundation
import Testing
@testable import SSMConnectKit

/// Runs every workflow conformance fixture in `contracts/fixtures/workflows` against the real
/// `ConnectionStateMachine`. This is the macOS half of AC-04: the Windows client runs the same
/// fixtures against `SSMConnect.Workflow`, and a disagreement between the two clients shows up
/// here, or there, as a failing case.
@Suite("Workflow conformance (contracts/fixtures/workflows)")
struct ConformanceTests {
    static let fixtureFiles: [URL] = FixturePaths.workflowFixtureFiles()

    @Test("every contract fixture is discovered")
    func fixturesAreDiscovered() {
        #expect(
            Self.fixtureFiles.count >= 28,
            "Expected at least 28 workflow fixtures in \(FixturePaths.workflowsDirectory.path), found \(Self.fixtureFiles.count)."
        )
    }

    @Test("conforms", arguments: fixtureFiles)
    @MainActor
    func conforms(file: URL) async throws {
        let fixture = try FixturePaths.loadFixture(at: file)
        let run = try await FixtureRunner(fixture: fixture).run()

        assertStates(fixture, run)
        assertCalls(fixture, run)
        assertForbiddenCalls(fixture, run)
        assertTerminal(fixture, run)
    }

    // MARK: - States

    private func assertStates(_ fixture: Fixture, _ run: FixtureRun) {
        let expected = fixture.expect.states
        let actual = run.states
        let rendering = """
            [\(fixture.id)] state sequence mismatch.
              expected: \(expected.joined(separator: " → "))
              actual:   \(actual.joined(separator: " → "))
            """

        if fixture.expect.statesAreExact {
            #expect(expected == actual, "\(rendering)")
        } else {
            #expect(isSubsequence(expected, of: actual), "\(rendering)  (expected as a subsequence)")
        }
    }

    private func isSubsequence(_ expected: [String], of actual: [String]) -> Bool {
        var cursor = 0
        for state in actual where cursor < expected.count && expected[cursor] == state {
            cursor += 1
        }
        return cursor == expected.count
    }

    // MARK: - Calls

    /// Asserts the listed calls occurred in the listed relative order. `times` is the total count
    /// for that port and method; `with` requires at least one such call to carry those arguments.
    /// Calls a fixture does not list are not constrained.
    private func assertCalls(_ fixture: Fixture, _ run: FixtureRun) {
        var cursor = -1
        for expected in fixture.expect.calls {
            guard let index = findCall(run.calls, expected, after: cursor) else {
                Issue.record("""
                    [\(fixture.id)] expected a call to \(expected)\(describe(expected.with)) after \
                    position \(cursor), but the recorded sequence was:
                        \(describe(run.calls))
                    """)
                continue
            }
            cursor = index

            if let times = expected.times {
                let actual = run.recorder.count(port: expected.port, method: expected.method)
                #expect(
                    actual == times,
                    """
                    [\(fixture.id)] expected \(times) call(s) to \(expected), saw \(actual).
                        \(describe(run.calls))
                    """
                )
            }
        }
    }

    private func assertForbiddenCalls(_ fixture: Fixture, _ run: FixtureRun) {
        for forbidden in fixture.expect.forbiddenCalls {
            let actual = run.recorder.count(port: forbidden.port, method: forbidden.method)
            #expect(actual == 0, "[\(fixture.id)] \(forbidden) must not be called, but it was called \(actual) time(s).")
        }
    }

    private func findCall(_ calls: [RecordedCall], _ expected: ExpectedCall, after: Int) -> Int? {
        calls.indices.dropFirst(after + 1).first { index in
            let call = calls[index]
            return call.port == expected.port && call.method == expected.method && matches(call, expected)
        }
    }

    private func matches(_ call: RecordedCall, _ expected: ExpectedCall) -> Bool {
        guard let with = expected.with else { return true }
        return with.allSatisfy { name, value in
            call.arguments[name]?.comparableText == value.comparableText
        }
    }

    // MARK: - Terminal

    @MainActor
    private func assertTerminal(_ fixture: Fixture, _ run: FixtureRun) {
        let expected = fixture.expect.terminal
        let machine = run.machine
        let trail = "States seen: \(run.states.joined(separator: " → "))"

        #expect(
            machine.state.rawValue == expected.state,
            "[\(fixture.id)] terminal state was '\(machine.state.rawValue)', expected '\(expected.state)'. \(trail)"
        )

        if let category = expected.errorCategory {
            #expect(
                machine.errorCategory.rawValue == category,
                """
                [\(fixture.id)] error category was '\(machine.errorCategory.rawValue)', \
                expected '\(category)'. Message: \(machine.errorMessage ?? "<none>")
                """
            )
        }

        if let fragment = expected.errorMessageContains {
            #expect(
                machine.errorMessage?.localizedCaseInsensitiveContains(fragment) == true,
                "[\(fixture.id)] expected the error message to contain '\(fragment)', got '\(machine.errorMessage ?? "<none>")'."
            )
        }

        if let warning = expected.warningPresent {
            #expect(
                (machine.warningMessage != nil) == warning,
                "[\(fixture.id)] expected warningPresent=\(warning), warning was '\(machine.warningMessage ?? "<none>")'."
            )
        }

        if let instanceId = expected.instanceId {
            #expect(
                machine.instanceId == instanceId,
                "[\(fixture.id)] instance ID was '\(machine.instanceId ?? "<null>")', expected '\(instanceId ?? "<null>")'."
            )
        }

        if let localPort = expected.localPort {
            #expect(
                machine.localPort == localPort,
                "[\(fixture.id)] local port was \(machine.localPort.map(String.init) ?? "<null>"), expected \(localPort.map(String.init) ?? "<null>")."
            )
        }

        if let tunnelActive = expected.tunnelActive {
            #expect(
                machine.tunnelActive == tunnelActive,
                "[\(fixture.id)] expected tunnelActive=\(tunnelActive), was \(machine.tunnelActive)."
            )
        }

        if let passwordInMemory = expected.passwordInMemory {
            #expect(
                (machine.password != nil) == passwordInMemory,
                "[\(fixture.id)] expected passwordInMemory=\(passwordInMemory), was \(machine.password != nil)."
            )
        }
    }

    // MARK: - Rendering

    private func describe(_ with: [String: JSONValue]?) -> String {
        guard let with, !with.isEmpty else { return "" }
        return " with " + with.keys.sorted().map { "\($0)=\(with[$0]!.comparableText ?? "null")" }.joined(separator: ", ")
    }

    private func describe(_ calls: [RecordedCall]) -> String {
        calls.isEmpty
            ? "<no calls>"
            : calls.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n        ")
    }
}
