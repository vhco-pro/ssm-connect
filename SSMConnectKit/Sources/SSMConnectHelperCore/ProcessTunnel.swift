import Foundation
import SSMConnectDomain
import SSMConnectWorkflow
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

/// The plugin port-forward tunnel on Windows and Linux: the bundled plugin as a child process
/// with the shared command line, ready once its local port accepts a TCP connection.
package struct ProcessTunnelProvider: TunnelProvider {
    let pluginPath: @Sendable () -> String?
    let verify: @Sendable (String) throws -> Void
    let readinessTimeout: Duration

    /// `verify` checks the exact plugin file before each launch (`InstallationCheck.plugin`).
    package init(pluginPath: @escaping @Sendable () -> String?, verify: @escaping @Sendable (String) throws -> Void = { _ in },
                 readinessTimeout: Duration = .seconds(15)) {
        self.pluginPath = pluginPath
        self.verify = verify
        self.readinessTimeout = readinessTimeout
    }

    package func checkAvailability() -> TunnelProviderStatus {
        guard let path = pluginPath() else { return .pluginMissing(path: "<unknown>") }
        return FileManager.default.fileExists(atPath: path) ? .available : .pluginMissing(path: path)
    }

    package func startTunnel(session: SSMSessionResponse, region: String, instanceId: String,
                             localPort: Int, remotePort: Int) async throws -> TunnelHandle {
        guard let path = pluginPath(), FileManager.default.fileExists(atPath: path) else {
            throw TunnelError.pluginMissing(path: pluginPath() ?? "<unknown>")
        }
        try verify(path)
        let process = ChildProcess(executable: path, arguments: try PluginArguments.portForward(
            session: session, region: region, instanceId: instanceId, localPort: localPort, remotePort: remotePort))
        let handle = ProcessTunnelHandle(process: process)
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard process.isRunning else {
                throw TunnelError.launchFailed(reason: "The plugin exited with code \(process.terminationStatus ?? -1).")
            }
            if tcpConnects(port: UInt16(localPort)) { return handle }
            try await Task.sleep(for: .milliseconds(250))
        }
        await handle.terminate()
        throw TunnelError.launchFailed(reason: "The plugin did not open local port \(localPort).")
    }
}

final class ProcessTunnelHandle: TunnelHandle, @unchecked Sendable {
    private let process: ChildProcess
    private let lock = NSLock()
    private var userTerminated = false
    let onDisconnect: AsyncStream<TunnelDropReason>

    /// Watches `process` for its exit; create it before the process runs.
    init(process: ChildProcess) {
        self.process = process
        var continuation: AsyncStream<TunnelDropReason>.Continuation!
        onDisconnect = AsyncStream { continuation = $0 }
        let stream = continuation!
        process.onExit { [weak self] code in
            let byUser = self?.lock.withLock { self?.userTerminated ?? false } ?? false
            stream.yield(byUser ? .terminatedByUser : .processExited(code: code, stderr: ""))
            stream.finish()
        }
    }

    var isActive: Bool { process.isRunning }
    var processIdentifier: Int32? { process.isRunning ? process.processIdentifier : nil }

    func terminate() async {
        lock.withLock { userTerminated = true }
        guard process.isRunning else { return }
        process.terminate()
        while process.isRunning { try? await Task.sleep(for: .milliseconds(50)) }
    }
}

/// A blocking TCP connect to 127.0.0.1:port; true when the connection is accepted.
func tcpConnects(port: UInt16) -> Bool {
    #if os(Windows)
    var data = WSADATA()
    guard WSAStartup(0x0202, &data) == 0 else { return false }
    defer { WSACleanup() }
    let handle = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
    guard handle != INVALID_SOCKET else { return false }
    defer { closesocket(handle) }
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let length = Int32(MemoryLayout<sockaddr_in>.size)
    #else
    #if canImport(Glibc)
    let handle = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let handle = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard handle >= 0 else { return false }
    defer { close(handle) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    #endif
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, length) }
    }
    return result == 0
}
