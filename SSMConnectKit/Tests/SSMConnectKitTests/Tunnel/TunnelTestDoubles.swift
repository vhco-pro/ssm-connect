import Foundation
@testable import SSMConnectKit

/// Controllable `SpawnedPluginProcess` for tunnel lifecycle tests — drive exit/running manually.
final class FakePluginProcess: SpawnedPluginProcess, @unchecked Sendable {
    private(set) var started = false
    private(set) var sigtermCount = 0
    private(set) var sigkillCount = 0
    var running = false
    var stderr = ""
    var startError: Error?
    /// When true, a SIGTERM gracefully exits the process (fires `onExit`); else it ignores SIGTERM
    /// and only SIGKILL stops it (exercises the grace-period → SIGKILL path).
    var respondsToSIGTERM = true
    var onExit: (@Sendable (Int32) -> Void)?
    let processIdentifier: Int32

    init(pid: Int32 = 1234) { self.processIdentifier = pid }

    var isRunning: Bool { running }

    func start() throws {
        if let startError { throw startError }
        started = true
        running = true
    }

    func sendSIGTERM() {
        sigtermCount += 1
        if respondsToSIGTERM {
            running = false
            onExit?(0)
        }
    }

    func sendSIGKILL() {
        sigkillCount += 1
        running = false
        onExit?(9)
    }

    func capturedStderr() -> String { stderr }

    /// Test helper: simulate the process exiting (fires the wired onExit handler).
    func simulateExit(code: Int32) {
        running = false
        onExit?(code)
    }
}

/// Records spawn calls and returns a preconfigured `FakePluginProcess`.
final class FakePluginSpawner: PluginSpawning, @unchecked Sendable {
    let process: FakePluginProcess
    private(set) var spawnCount = 0
    private(set) var lastArguments: [String]?
    private(set) var lastExecutablePath: String?

    init(process: FakePluginProcess = FakePluginProcess()) { self.process = process }

    func spawn(executablePath: String, arguments: [String]) -> SpawnedPluginProcess {
        spawnCount += 1
        lastExecutablePath = executablePath
        lastArguments = arguments
        return process
    }
}

struct StubPortProbe: PortProbing {
    var occupantToReturn: PortOccupant?
    func occupant(of port: Int) -> PortOccupant? { occupantToReturn }
}

/// Port probe whose occupant can change (e.g. cleared when a stale plugin is killed) so the
/// reclaim path (spec §8) is testable.
final class ReclaimablePortProbe: PortProbing, @unchecked Sendable {
    var occupant: PortOccupant?
    var killed: Int32?
    init(occupant: PortOccupant?) { self.occupant = occupant }
    func occupant(of port: Int) -> PortOccupant? { occupant }
}
