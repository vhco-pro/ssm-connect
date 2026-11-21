import Foundation
import Testing
@testable import SSMConnectHelperProtocol

/// The helper protocol with fake ports (T14, AC-27): framing, the build handshake, one terminal
/// result per admitted command, refusal before side effects, cooperative cancel isolation and
/// heartbeats; and the helper executable's stdin/stdout contract.
@Suite("Helper protocol")
struct ProtocolTests {
    /// Collects every frame the session sends, in order.
    final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Frame] = []
        func send(_ frame: Frame) { lock.withLock { frames.append(frame) } }
        var all: [Frame] { lock.withLock { frames } }
        func results(for id: String) -> [Outcome] {
            all.compactMap { if case let .result(rid, outcome) = $0, rid == id { return outcome } else { return nil } }
        }
    }

    /// A fake port that records side effects and runs until released or cancelled.
    final class FakeWorkflow: @unchecked Sendable {
        private let lock = NSLock()
        private var effects = 0
        private var gate: CheckedContinuation<Void, Never>?
        private var released = false
        var sideEffects: Int { lock.withLock { effects } }
        func release() {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock { released = true; defer { gate = nil }; return gate }
            waiting?.resume()
        }
        func run() async throws -> [String: String] {
            lock.withLock { effects += 1 }
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let resumeNow: Bool = lock.withLock { if released { return true }; gate = continuation; return false }
                    if resumeNow { continuation.resume() }
                }
            } onCancel: { self.release() }
            try Task.checkCancellation()
            return ["done": "yes"]
        }
    }

    static func session(_ outbox: Outbox, commands: [String: CommandSpec], build: String = "build-1") -> HelperSession {
        HelperSession(build: build, commands: commands, send: { outbox.send($0) })
    }

    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: Framing

    @Test("Frames are one JSON object per line, split across reads, with CRLF tolerated")
    func framing() throws {
        var reader = FrameReader()
        let hello = try FrameCodec.encode(.hello(build: "b", protocolVersion: 1))
        #expect(hello.last == 0x0A && !hello.dropLast().contains(0x0A))
        var lines = try reader.append(hello.prefix(5))
        #expect(lines.isEmpty)
        lines = try reader.append(hello.dropFirst(5) + Data("{\"type\":\"heartbeat\",\"sequence\":7}\r\n".utf8))
        #expect(try lines.map(FrameCodec.decode) == [.hello(build: "b", protocolVersion: 1), .heartbeat(sequence: 7)])
    }

    @Test("Every frame type round-trips")
    func roundTrip() throws {
        let frames: [Frame] = [
            .hello(build: "b", protocolVersion: 1), .welcome(build: "b"),
            .refused(reason: "differentBuild", detail: "helper b2"),
            .command(id: "c1", name: "connect", arguments: ["profile": "p"]), .cancel(id: "c1"),
            .heartbeat(sequence: 3), .shutdown, .accepted(id: "c1"),
            .rejected(id: "c1", error: HelperError(code: "busy", message: "m")),
            .result(id: "c1", outcome: .completed(["k": "v"])),
            .result(id: "c1", outcome: .failed(HelperError(code: "x", message: "y"))),
            .result(id: "c1", outcome: .cancelled),
            .event(sequence: 1, workflow: "desktop", name: "state", fields: ["state": "connected"]),
        ]
        for frame in frames { #expect(try FrameCodec.decode(FrameCodec.encode(frame).dropLast()) == frame) }
    }

    @Test("An oversized or malformed frame is a framing error")
    func framingErrors() {
        var reader = FrameReader()
        #expect(throws: FrameError.tooLong) { _ = try reader.append(Data(repeating: 0x61, count: FrameReader.maximumLength + 1)) }
        #expect(throws: FrameError.malformed) { _ = try FrameCodec.decode(Data("not json".utf8)) }
        #expect(throws: FrameError.malformed) { _ = try FrameCodec.decode(Data("{\"type\":\"nope\"}".utf8)) }
    }

    // MARK: Handshake

    @Test("A different build is refused at handshake and nothing else is admitted")
    func handshakeRefusesOtherBuild() async {
        let outbox = Outbox()
        let workflow = FakeWorkflow()
        let session = Self.session(outbox, commands: ["connect": CommandSpec(workflow: "desktop", run: { _, _ in try await workflow.run() })])
        await session.receive(.hello(build: "build-2", protocolVersion: 1))
        await session.receive(.command(id: "c1", name: "connect", arguments: [:]))
        #expect(outbox.all.first == .refused(reason: "differentBuild", detail: "helper build-1, shell build-2"))
        #expect(await session.isEnded)
        #expect(workflow.sideEffects == 0 && outbox.results(for: "c1").isEmpty)
    }

    @Test("The same build is welcomed; a command before the handshake is rejected")
    func handshakeWelcomes() async {
        let outbox = Outbox()
        let session = Self.session(outbox, commands: [:])
        await session.receive(.command(id: "early", name: "connect", arguments: [:]))
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        #expect(outbox.all == [.rejected(id: "early", error: HelperError(code: "handshakeRequired", message: "The helper has not completed its handshake.")),
                               .welcome(build: "build-1")])
    }

    // MARK: Commands

    @Test("Two concurrent commands each get exactly one terminal result")
    func concurrentCommands() async {
        let outbox = Outbox()
        let desktop = FakeWorkflow(), editor = FakeWorkflow()
        let session = Self.session(outbox, commands: [
            "connect": CommandSpec(workflow: "desktop", run: { _, _ in try await desktop.run() }),
            "openEditor": CommandSpec(workflow: "editor", run: { _, _ in try await editor.run() }),
        ])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.receive(.command(id: "b", name: "openEditor", arguments: [:]))
        editor.release(); desktop.release()
        await Self.waitUntil { !outbox.results(for: "a").isEmpty && !outbox.results(for: "b").isEmpty }
        await session.awaitIdle()
        #expect(outbox.results(for: "a") == [.completed(["done": "yes"])])
        #expect(outbox.results(for: "b") == [.completed(["done": "yes"])])
        #expect(outbox.all.filter { $0 == .accepted(id: "a") || $0 == .accepted(id: "b") }.count == 2)
    }

    @Test("A command conflicting with current state is refused before any side effect")
    func refusalBeforeSideEffects() async {
        let outbox = Outbox()
        let workflow = FakeWorkflow()
        let session = Self.session(outbox, commands: [
            "connect": CommandSpec(workflow: "desktop",
                                   admit: { _ in throw HelperError(code: "notConfigured", message: "Configure the profile first.") },
                                   run: { _, _ in try await workflow.run() }),
        ])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.awaitIdle()
        #expect(outbox.all.last == .rejected(id: "a", error: HelperError(code: "notConfigured", message: "Configure the profile first.")))
        #expect(workflow.sideEffects == 0 && outbox.results(for: "a").isEmpty)
    }

    @Test("A busy workflow, an unknown command and a reused ID are refused")
    func refusals() async {
        let outbox = Outbox()
        let workflow = FakeWorkflow()
        let session = Self.session(outbox, commands: ["connect": CommandSpec(workflow: "desktop", run: { _, _ in try await workflow.run() })])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.receive(.command(id: "b", name: "connect", arguments: [:]))
        await session.receive(.command(id: "c", name: "nope", arguments: [:]))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        let rejections = outbox.all.compactMap { if case let .rejected(id, error) = $0 { return "\(id):\(error.code)" } else { return nil } }
        #expect(rejections == ["b:busy", "c:unknownCommand", "a:duplicateID"])
        workflow.release()
        await session.awaitIdle()
        #expect(workflow.sideEffects == 1 && outbox.results(for: "a").count == 1)
    }

    @Test("Cancelling one workflow leaves a second running")
    func cancelIsolation() async {
        let outbox = Outbox()
        let desktop = FakeWorkflow(), editor = FakeWorkflow()
        let session = Self.session(outbox, commands: [
            "connect": CommandSpec(workflow: "desktop", run: { _, _ in try await desktop.run() }),
            "openEditor": CommandSpec(workflow: "editor", run: { _, _ in try await editor.run() }),
        ])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.receive(.command(id: "b", name: "openEditor", arguments: [:]))
        await Self.waitUntil { desktop.sideEffects == 1 && editor.sideEffects == 1 }
        await session.receive(.cancel(id: "a"))
        await Self.waitUntil { !outbox.results(for: "a").isEmpty }
        #expect(outbox.results(for: "a") == [.cancelled])
        #expect(outbox.results(for: "b").isEmpty)
        editor.release()
        await session.awaitIdle()
        #expect(outbox.results(for: "b") == [.completed(["done": "yes"])])
    }

    @Test("A failure is one failed result with its typed error")
    func failure() async {
        let outbox = Outbox()
        let session = Self.session(outbox, commands: [
            "connect": CommandSpec(workflow: "desktop", run: { _, _ in throw HelperError(code: "signInRequired", message: "Sign in.") }),
        ])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.awaitIdle()
        #expect(outbox.results(for: "a") == [.failed(HelperError(code: "signInRequired", message: "Sign in."))])
    }

    @Test("Heartbeats are answered while a command runs, and events are ordered")
    func heartbeatAndEvents() async {
        let outbox = Outbox()
        let workflow = FakeWorkflow()
        let session = Self.session(outbox, commands: [
            "connect": CommandSpec(workflow: "desktop", run: { _, events in
                events.emit(workflow: "desktop", name: "state", fields: ["state": "authenticating"])
                events.emit(workflow: "desktop", name: "state", fields: ["state": "connected"])
                return try await workflow.run()
            }),
        ])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await Self.waitUntil { workflow.sideEffects == 1 }
        await session.receive(.heartbeat(sequence: 42))
        #expect(outbox.all.contains(.heartbeat(sequence: 42)))
        #expect(outbox.results(for: "a").isEmpty)
        let events = outbox.all.compactMap { if case let .event(sequence, _, _, fields) = $0 { return "\(sequence):\(fields["state"] ?? "")" } else { return nil } }
        #expect(events == ["1:authenticating", "2:connected"])
        workflow.release()
        await session.awaitIdle()
    }

    @Test("Shutdown cancels in-flight commands, each with one terminal result")
    func shutdown() async {
        let outbox = Outbox()
        let workflow = FakeWorkflow()
        let session = Self.session(outbox, commands: ["connect": CommandSpec(workflow: "desktop", run: { _, _ in try await workflow.run() })])
        await session.receive(.hello(build: "build-1", protocolVersion: 1))
        await session.receive(.command(id: "a", name: "connect", arguments: [:]))
        await session.receive(.shutdown)
        #expect(outbox.results(for: "a") == [.cancelled])
        #expect(await session.isEnded)
    }

    // MARK: Executable

    /// The built helper in the build products directory that holds the test bundle or binary.
    static var helperExecutable: URL {
        #if os(Windows)
        let name = "SSMConnectHelper.exe"
        #else
        let name = "SSMConnectHelper"
        #endif
        let bundle = Bundle(for: Marker.self).bundleURL
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [bundle, bundle.deletingLastPathComponent(), binary, binary.deletingLastPathComponent(),
                          bundle.appendingPathComponent("debug"), bundle.appendingPathComponent("release")]
        return candidates.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? bundle.appendingPathComponent(name)
    }
    final class Marker {}

    static func run(_ arguments: [String], input: Data) throws -> (status: Int32, stdout: Data, stderr: String) {
        let process = Process()
        process.executableURL = Self.helperExecutable
        process.arguments = arguments
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, out, err)
    }

    @Test("The helper speaks only frames on stdout, diagnoses on stderr and exits on stdin EOF")
    func executable() throws {
        let version = try Self.run(["--build"], input: Data())
        let build = String(decoding: version.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(version.status == 0 && !build.isEmpty)
        let input = try FrameCodec.encode(.hello(build: build, protocolVersion: 1)) + Data("garbage\n".utf8)
            + FrameCodec.encode(.heartbeat(sequence: 9))
        let result = try Self.run([], input: input)
        #expect(result.status == 0)
        var reader = FrameReader()
        #expect(try reader.append(result.stdout).map(FrameCodec.decode) == [.welcome(build: build), .heartbeat(sequence: 9)])
        #expect(result.stderr.contains("malformed frame"))
    }

    @Test("The helper exits non-zero after refusing a different build")
    func executableRefusesOtherBuild() throws {
        let result = try Self.run([], input: try FrameCodec.encode(.hello(build: "another-build", protocolVersion: 1)))
        #expect(result.status != 0)
        var reader = FrameReader()
        let frames = try reader.append(result.stdout).map(FrameCodec.decode)
        guard case .refused(reason: "differentBuild", _) = frames.first else { Issue.record("not refused: \(frames)"); return }
    }
}
