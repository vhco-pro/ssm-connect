import Darwin
import Foundation

/// `TunnelProvider` that shells out to the bundled AWS `session-manager-plugin` (D4, ADR-1).
///
/// Constructs the 5-argument plugin command line (spec §6.4), checks the local port is free,
/// launches the child process, and returns a `BundledPluginTunnelHandle` for lifecycle control.
final class BundledPluginTunnel: TunnelProvider {
    private let pluginPath: @Sendable () -> String?
    private let spawner: PluginSpawning
    private let portProbe: PortProbing
    private let killProcess: @Sendable (Int32) -> Void
    private let terminationGracePeriod: Duration
    private let terminationPollInterval: Duration

    init(
        pluginPath: @escaping @Sendable () -> String? = { BundledPluginTunnel.defaultPluginPath() },
        spawner: PluginSpawning = ProcessPluginSpawner(),
        portProbe: PortProbing = SystemPortProbe(),
        killProcess: @escaping @Sendable (Int32) -> Void = { kill($0, SIGKILL) },
        terminationGracePeriod: Duration = .seconds(5),
        terminationPollInterval: Duration = .milliseconds(100)
    ) {
        self.pluginPath = pluginPath
        self.spawner = spawner
        self.portProbe = portProbe
        self.killProcess = killProcess
        self.terminationGracePeriod = terminationGracePeriod
        self.terminationPollInterval = terminationPollInterval
    }

    /// The bundled plugin lives in `Contents/Helpers/` (embedded by the build phase, ADR-7).
    static func defaultPluginPath() -> String? {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/session-manager-plugin")
            .path
    }

    // MARK: - TunnelProvider

    func checkAvailability() -> TunnelProviderStatus {
        guard let path = pluginPath() else { return .pluginMissing(path: "<unknown>") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return .pluginMissing(path: path) }
        guard fm.isExecutableFile(atPath: path) else { return .pluginNotExecutable(path: path) }
        return .available
    }

    func startTunnel(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) async throws -> TunnelHandle {
        // D7: validate the plugin binary before anything else.
        switch checkAvailability() {
        case .available:
            break
        case let .pluginMissing(path):
            throw TunnelError.pluginMissing(path: path)
        case let .pluginNotExecutable(path):
            throw TunnelError.pluginNotExecutable(path: path)
        }
        guard let path = pluginPath() else { throw TunnelError.pluginMissing(path: "<unknown>") }

        // D6 / spec §8: if the local port is taken by a STALE copy of our own plugin (orphaned by a
        // previous crash or a quit that didn't clean up), reclaim it; otherwise refuse to start.
        if let occupant = portProbe.occupant(of: localPort) {
            let isOwnPlugin = occupant.processName?.contains("session-manager-plugin") ?? false
            if isOwnPlugin, let pid = occupant.pid {
                killProcess(pid)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while portProbe.occupant(of: localPort) != nil, ContinuousClock.now < deadline {
                    Thread.sleep(forTimeInterval: 0.1)
                }
            }
            if let blocker = portProbe.occupant(of: localPort) {
                throw TunnelError.localPortInUse(port: localPort, pid: blocker.pid, processName: blocker.processName)
            }
        }

        let arguments = try Self.pluginArguments(
            session: session, region: region, instanceId: instanceId,
            localPort: localPort, remotePort: remotePort
        )
        let process = spawner.spawn(executablePath: path, arguments: arguments)
        let handle = BundledPluginTunnelHandle(
            process: process,
            gracePeriod: terminationGracePeriod,
            pollInterval: terminationPollInterval
        )
        try handle.start()
        return handle
    }

    /// Build the 5-arg plugin invocation (spec §6.4).
    static func pluginArguments(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) throws -> [String] {
        let sessionJSON = try session.pluginSessionJSON()
        let parameters: [String: Any] = [
            "Target": instanceId,
            "DocumentName": SSMService.portForwardDocument,
            "Parameters": [
                "portNumber": [String(remotePort)],
                "localPortNumber": [String(localPort)],
            ],
        ]
        let paramData = try JSONSerialization.data(withJSONObject: parameters)
        let paramJSON = String(decoding: paramData, as: UTF8.self)
        return [sessionJSON, region, "StartSession", "", paramJSON]
    }
}

/// A live bundled-plugin tunnel (D5). Monitors the child process, emits on drop, tears down with
/// SIGTERM → grace period → SIGKILL.
final class BundledPluginTunnelHandle: TunnelHandle, @unchecked Sendable {
    private let process: SpawnedPluginProcess
    private let gracePeriod: Duration
    private let pollInterval: Duration
    private let continuation: AsyncStream<TunnelDropReason>.Continuation
    let onDisconnect: AsyncStream<TunnelDropReason>

    private let lock = NSLock()
    private var userInitiated = false
    private var finished = false

    init(process: SpawnedPluginProcess, gracePeriod: Duration, pollInterval: Duration) {
        self.process = process
        self.gracePeriod = gracePeriod
        self.pollInterval = pollInterval
        var captured: AsyncStream<TunnelDropReason>.Continuation!
        self.onDisconnect = AsyncStream { captured = $0 }
        self.continuation = captured
        // Wire the exit handler BEFORE the process starts so no exit is missed.
        process.onExit = { [weak self] code in self?.handleExit(code: code) }
    }

    func start() throws {
        try process.start()
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return !finished && process.isRunning
    }

    var processIdentifier: Int32? {
        let pid = process.processIdentifier
        return pid > 0 ? pid : nil
    }

    func terminate() async {
        lock.lock()
        let alreadyDone = finished
        if !finished { userInitiated = true }
        lock.unlock()
        guard !alreadyDone, process.isRunning else { return }

        process.sendSIGTERM()
        let deadline = ContinuousClock.now.advanced(by: gracePeriod)
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(for: pollInterval)
        }
        if process.isRunning { process.sendSIGKILL() }
    }

    private func handleExit(code: Int32) {
        lock.lock()
        if finished { lock.unlock(); return }
        finished = true
        let wasUserInitiated = userInitiated
        lock.unlock()

        let reason: TunnelDropReason = wasUserInitiated
            ? .terminatedByUser
            : .processExited(code: code, stderr: process.capturedStderr())
        continuation.yield(reason)
        continuation.finish()
    }
}
