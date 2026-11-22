import Foundation
import SSMConnectDomain
import SSMConnectWorkflow
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

/// Web forwards on Windows and Linux: OpenSSH as a child process with the shared command line,
/// the plugin as its ProxyCommand, ready once every forwarded port accepts a connection.
package struct ProcessSSHTunnel: SSHTunnelProviding {
    let sshPath: @Sendable () -> String?
    let pluginPath: @Sendable () -> String?
    let style: SSHArguments.Style
    let verify: @Sendable (String) throws -> Void
    let readinessTimeout: Duration

    /// `verify` checks the exact plugin file before each launch (`InstallationCheck.plugin`).
    package init(sshPath: @escaping @Sendable () -> String?, pluginPath: @escaping @Sendable () -> String?,
                 style: SSHArguments.Style, verify: @escaping @Sendable (String) throws -> Void = { _ in },
                 readinessTimeout: Duration = .seconds(15)) {
        self.sshPath = sshPath
        self.pluginPath = pluginPath
        self.style = style
        self.verify = verify
        self.readinessTimeout = readinessTimeout
    }

    package func unavailableCapabilities() -> [Capability] {
        var missing: [Capability] = []
        if pluginPath().map({ FileManager.default.fileExists(atPath: $0) }) != true { missing.append(.sessionManagerPlugin) }
        if sshPath().map({ FileManager.default.fileExists(atPath: $0) }) != true { missing.append(.openSSH) }
        return missing
    }

    package func start(session: SSMSessionResponse, region: String, instanceId: String, user: String,
                       keyPath: String, configuration: WebForwardsConfiguration) async throws -> TunnelHandle {
        guard let ssh = sshPath(), let plugin = pluginPath() else { throw WebForwardsError.sshNotReady }
        try verify(plugin)
        let ports = configuration.localForwards.map(\.localPort) + (configuration.socksPort.map { [$0] } ?? [])
        for port in ports where tcpConnects(port: UInt16(port)) {
            throw TunnelError.localPortInUse(port: port, pid: nil, processName: nil)
        }
        let process = ChildProcess(
            executable: ssh,
            arguments: try SSHArguments.webForwards(pluginPath: plugin, region: region, instanceId: instanceId,
                                                    user: user, keyPath: keyPath, configuration: configuration, style: style),
            environment: ProcessInfo.processInfo.environment.merging(
                ["AWS_SSM_START_SESSION_RESPONSE": try session.pluginSessionJSON()]) { _, new in new })
        let handle = ProcessTunnelHandle(process: process)
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: readinessTimeout)
        do {
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw WebForwardsError.sshNotReady }
                if ports.allSatisfy({ tcpConnects(port: UInt16($0)) }) { return handle }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw WebForwardsError.sshNotReady
        } catch {
            await handle.terminate()
            throw error
        }
    }
}

/// Whether a local port accepts a TCP connection (the tunnel-up assertion).
package struct TCPPortListenerProbe: TunnelListenerProbing {
    package init() {}
    package func isListening(host: String, port: Int, timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        repeat {
            if tcpConnects(port: UInt16(port)) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        } while ContinuousClock.now < deadline
        return false
    }
}

/// The workstation's server is ready once a TLS ClientHello sent through the tunnel gets any
/// TLS record back. The plugin accepts locally before the remote server listens, so a bare TCP
/// connect would say ready too early; the workstation's certificate is self-signed, so the
/// probe needs no trust decision, only an answer.
package struct TLSReadinessProbe: WorkstationReadinessProbing {
    package init() {}

    package func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await Task.detached(operation: { tlsAnswers(port: UInt16(port)) }).value { return true }
            try? await Task.sleep(for: interval)
        }
        return false
    }
}

/// A minimal TLS 1.2 ClientHello: one AES-GCM suite with ECDHE, no extensions beyond the
/// supported groups and signature algorithms a server needs to answer.
private let clientHello: [UInt8] = {
    let suites: [UInt8] = [0x00, 0x04, 0xC0, 0x2F, 0xC0, 0x2B]
    let groups: [UInt8] = [0x00, 0x0A, 0x00, 0x04, 0x00, 0x02, 0x00, 0x17]
    let signatures: [UInt8] = [0x00, 0x0D, 0x00, 0x06, 0x00, 0x04, 0x04, 0x01, 0x04, 0x03]
    let points: [UInt8] = [0x00, 0x0B, 0x00, 0x02, 0x01, 0x00]
    let extensions = groups + signatures + points
    var body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 0x2A, count: 32) + [0x00] + suites + [0x01, 0x00]
    body += [UInt8(extensions.count >> 8), UInt8(extensions.count & 0xFF)] + extensions
    let handshake: [UInt8] = [0x01, 0x00, UInt8(body.count >> 8), UInt8(body.count & 0xFF)] + body
    return [0x16, 0x03, 0x01, UInt8(handshake.count >> 8), UInt8(handshake.count & 0xFF)] + handshake
}()

/// Connects, sends the ClientHello and waits up to two seconds for a TLS record header.
func tlsAnswers(port: UInt16) -> Bool {
    #if os(Windows)
    var data = WSADATA()
    guard WSAStartup(0x0202, &data) == 0 else { return false }
    defer { WSACleanup() }
    let handle = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
    guard handle != INVALID_SOCKET else { return false }
    defer { closesocket(handle) }
    var timeout = DWORD(2000)
    _ = setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, withUnsafeBytes(of: &timeout) { $0.baseAddress!.assumingMemoryBound(to: CChar.self) },
                   Int32(MemoryLayout<DWORD>.size))
    var address = sockaddr_in()
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
    } == 0
    guard connected else { return false }
    let sent = clientHello.withUnsafeBufferPointer { buffer in
        buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) { send(handle, $0, Int32(buffer.count), 0) }
    }
    guard sent == Int32(clientHello.count) else { return false }
    var reply = [CChar](repeating: 0, count: 5)
    let received = recv(handle, &reply, 5, 0)
    return received > 0 && (UInt8(bitPattern: reply[0]) == 0x16 || UInt8(bitPattern: reply[0]) == 0x15)
    #else
    #if canImport(Glibc)
    let handle = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #else
    let handle = socket(AF_INET, SOCK_STREAM, 0)
    #endif
    guard handle >= 0 else { return false }
    defer { close(handle) }
    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
    guard connected else { return false }
    let sent = clientHello.withUnsafeBytes { send(handle, $0.baseAddress, $0.count, 0) }
    guard sent == clientHello.count else { return false }
    var reply = [UInt8](repeating: 0, count: 5)
    let received = recv(handle, &reply, 5, 0)
    return received > 0 && (reply[0] == 0x16 || reply[0] == 0x15)
    #endif
}
