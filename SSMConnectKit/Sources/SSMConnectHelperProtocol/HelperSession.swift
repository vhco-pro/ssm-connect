import Foundation

/// Emits ordered events for the shell: each gets the next sequence number, and frames leave in
/// that order.
package final class EventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private let send: @Sendable (Frame) -> Void

    init(send: @escaping @Sendable (Frame) -> Void) { self.send = send }

    package func emit(workflow: String, name: String, fields: [String: String] = [:]) {
        lock.withLock {
            sequence += 1
            send(.event(sequence: sequence, workflow: workflow, name: name, fields: fields))
        }
    }
}

/// A command the core knows. `workflow` names the workflow it drives: one command per workflow
/// runs at a time, and cancelling one never touches another. `admit` runs before any side
/// effect and refuses the command by throwing a `HelperError`; `run` does the work.
package struct CommandSpec: Sendable {
    package let workflow: String
    package let admit: @Sendable ([String: String]) async throws -> Void
    package let run: @Sendable ([String: String], EventSink) async throws -> [String: String]

    package init(workflow: String,
                 admit: @escaping @Sendable ([String: String]) async throws -> Void = { _ in },
                 run: @escaping @Sendable ([String: String], EventSink) async throws -> [String: String]) {
        self.workflow = workflow
        self.admit = admit
        self.run = run
    }
}

/// The helper side of the protocol. The core alone owns state: it admits or refuses each
/// command before any side effect, answers every admitted command with exactly one terminal
/// result, cancels cooperatively per command, and answers heartbeats while commands run.
package actor HelperSession {
    private let build: String
    private let commands: [String: CommandSpec]
    private let send: @Sendable (Frame) -> Void
    package nonisolated let events: EventSink
    private var welcomed = false
    package private(set) var isEnded = false
    /// Whether the session ended by refusing the shell's handshake.
    package private(set) var wasRefused = false
    private var seenIDs: Set<String> = []
    private var running: [String: (workflow: String, task: Task<Void, Never>)] = [:]

    package init(build: String, commands: [String: CommandSpec], send: @escaping @Sendable (Frame) -> Void) {
        self.build = build
        self.commands = commands
        self.send = send
        self.events = EventSink(send: send)
    }

    package func receive(_ frame: Frame) async {
        guard !isEnded else { return }
        switch frame {
        case let .hello(shellBuild, version):
            guard !welcomed else { return }
            if shellBuild == build, version == helperProtocolVersion {
                welcomed = true
                send(.welcome(build: build))
            } else if shellBuild != build {
                send(.refused(reason: "differentBuild", detail: "helper \(build), shell \(shellBuild)"))
                isEnded = true
                wasRefused = true
            } else {
                send(.refused(reason: "differentProtocol", detail: "helper \(helperProtocolVersion), shell \(version)"))
                isEnded = true
                wasRefused = true
            }
        case let .command(id, name, arguments):
            await admit(id: id, name: name, arguments: arguments)
        case let .cancel(id):
            running[id]?.task.cancel()
        case let .heartbeat(sequence):
            send(.heartbeat(sequence: sequence))
        case .shutdown:
            await shutdown()
        case .welcome, .refused, .accepted, .rejected, .result, .event:
            break // helper-to-shell frames are ignored if echoed back
        }
    }

    /// Cancels every running command, waits for their terminal results, and ends the session.
    package func shutdown() async {
        let tasks = running.values.map(\.task)
        tasks.forEach { $0.cancel() }
        for task in tasks { await task.value }
        isEnded = true
    }

    /// Waits until no command is running.
    package func awaitIdle() async {
        while let task = running.values.first?.task { await task.value }
    }

    private func admit(id: String, name: String, arguments: [String: String]) async {
        func reject(_ code: String, _ message: String) { send(.rejected(id: id, error: HelperError(code: code, message: message))) }
        guard welcomed else { return reject("handshakeRequired", "The helper has not completed its handshake.") }
        guard !seenIDs.contains(id) else { return reject("duplicateID", "Command \(id) was already received.") }
        seenIDs.insert(id)
        guard let spec = commands[name] else { return reject("unknownCommand", "The helper does not know \(name).") }
        guard !running.values.contains(where: { $0.workflow == spec.workflow }) else {
            return reject("busy", "Another \(spec.workflow) action is in progress.")
        }
        do {
            try await spec.admit(arguments)
        } catch let error as HelperError {
            return reject(error.code, error.message)
        } catch {
            return reject("refused", error.localizedDescription)
        }
        // The admission check may suspend; recheck the workflow before admitting.
        guard !running.values.contains(where: { $0.workflow == spec.workflow }) else {
            return reject("busy", "Another \(spec.workflow) action is in progress.")
        }
        send(.accepted(id: id))
        let events = self.events
        let task = Task {
            let outcome: Outcome
            do {
                outcome = .completed(try await spec.run(arguments, events))
            } catch is CancellationError {
                outcome = .cancelled
            } catch let error as HelperError {
                outcome = Task.isCancelled ? .cancelled : .failed(error)
            } catch {
                outcome = Task.isCancelled ? .cancelled : .failed(HelperError(code: "failed", message: error.localizedDescription))
            }
            await self.finish(id: id, outcome: outcome)
        }
        running[id] = (spec.workflow, task)
    }

    private func finish(id: String, outcome: Outcome) {
        guard running.removeValue(forKey: id) != nil else { return }
        send(.result(id: id, outcome: outcome))
    }
}
