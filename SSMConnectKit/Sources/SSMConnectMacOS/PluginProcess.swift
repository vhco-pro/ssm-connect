import Darwin
import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

/// A spawned (but possibly not-yet-started) `session-manager-plugin` child process.
/// Abstracted so `BundledPluginTunnel`'s lifecycle logic is unit-testable without a real binary (D8).
package protocol SpawnedPluginProcess: AnyObject {
    var processIdentifier: Int32 { get }
    var isRunning: Bool { get }
    /// Invoked once when the process exits, with its exit code. Wired by the tunnel handle
    /// *before* `start()` so no exit is missed.
    var onExit: (@Sendable (Int32) -> Void)? { get set }
    func start() throws
    func sendSIGTERM()
    func sendSIGKILL()
    /// Best-effort captured stderr (for surfacing the failure reason on an unexpected exit).
    func capturedStderr() -> String
    func setEnvironment(_ environment: [String: String])
}

/// Spawns plugin child processes. Real impl wraps `Foundation.Process`; mocked in tests.
package protocol PluginSpawning: Sendable {
    func spawn(executablePath: String, arguments: [String]) -> SpawnedPluginProcess
}

/// Describes a process occupying a TCP port (spec §8 port-in-use handling).
package struct PortOccupant: Equatable, Sendable {
    package let pid: Int32?
    package let processName: String?

    package init(pid: Int32?, processName: String?) {
        self.pid = pid
        self.processName = processName
    }
}

/// Probes whether a local TCP port is already in use. Mocked in tests.
package protocol PortProbing: Sendable {
    /// Returns occupant info if `port` on `127.0.0.1` is accepting connections, else `nil`.
    func occupant(of port: Int) -> PortOccupant?
}

// MARK: - Real implementations

/// `Foundation.Process`-backed plugin process.
package final class ProcessPluginProcess: SpawnedPluginProcess, @unchecked Sendable {
    private let process = Process()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var stderrBuffer = Data()
    package var onExit: (@Sendable (Int32) -> Void)?

    package init(executablePath: String, arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardError = stderrPipe
        // The plugin writes keepalive/progress lines to stdout for the life of the session.
        // We don't consume them, so discard to /dev/null — an unread Pipe would fill its ~64KB
        // OS buffer and block the plugin's write(), stalling the data channel and the tunnel.
        process.standardOutput = FileHandle.nullDevice
    }

    package func start() throws {
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.lock.lock()
            self?.stderrBuffer.append(data)
            self?.lock.unlock()
        }
        process.terminationHandler = { [weak self] proc in
            self?.stderrPipe.fileHandleForReading.readabilityHandler = nil
            self?.onExit?(proc.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            throw TunnelError.launchFailed(reason: error.localizedDescription)
        }
    }

    package var processIdentifier: Int32 { process.processIdentifier }
    package var isRunning: Bool { process.isRunning }
    package func setEnvironment(_ environment: [String: String]) {
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    }
    package func sendSIGTERM() { kill(process.processIdentifier, SIGTERM) }
    package func sendSIGKILL() { kill(process.processIdentifier, SIGKILL) }

    package func capturedStderr() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: stderrBuffer, as: UTF8.self)
    }
}

package struct ProcessPluginSpawner: PluginSpawning {
    package func spawn(executablePath: String, arguments: [String]) -> SpawnedPluginProcess {
        ProcessPluginProcess(executablePath: executablePath, arguments: arguments)
    }

    package init() {}
}

/// BSD-socket port probe: a successful `connect()` to `127.0.0.1:port` means the port is in use.
/// PID/process-name are looked up best-effort via `lsof`.
package struct SystemPortProbe: PortProbing {
    package func occupant(of port: Int) -> PortOccupant? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected else { return nil }
        return Self.lsofOccupant(port: port) ?? PortOccupant(pid: nil, processName: nil)
    }

    /// Best-effort `lsof` lookup of the listening process for `port`.
    private static func lsofOccupant(port: Int) -> PortOccupant? {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        do {
            try lsof.run()
            lsof.waitUntilExit()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)
        var pid: Int32?
        var name: String?
        for line in output.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "c": name = String(line.dropFirst())
            default: break
            }
        }
        guard pid != nil || name != nil else { return nil }
        return PortOccupant(pid: pid, processName: name)
    }

    package init() {}
}
