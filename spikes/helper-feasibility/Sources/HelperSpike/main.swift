import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif
import SSMConnectAWSClient

// Feasibility helper for T4/T5. Reads one JSON command per line on stdin and writes one
// JSON event per line on stdout; diagnostics go to stderr. Credentials and tokens stay in
// this process and are never written out.
//
// Commands (each may carry an "id" echoed on its events):
//   {"cmd":"signIn","startUrl":..,"ssoRegion":..,"accountId":..,"roleName":..,"region":..}
//   {"cmd":"refresh"}                       SSO token refresh, then new role credentials
//   {"cmd":"identity"}                      STS caller identity and the derived username
//   {"cmd":"describe","tagKey":..,"tagValue":..}
//   {"cmd":"tunnel","instanceId":..,"remotePort":..,"localPort":..,"pluginPath":..}
//   {"cmd":"stop"}                          ends the plugin process
//   {"cmd":"cancel"}                        cancels the action in progress (sign-in polling or a
//                                           tunnel start); that action reports "cancelled"
//   {"cmd":"quit"} or end of input          cancels any action, ends any plugin process and exits
//
// One action runs at a time; commands keep being read while it runs, so a cancel or quit
// reaches it.

final class Output: @unchecked Sendable {
    private let lock = NSLock()
    func emit(_ id: String?, _ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["event"] = event
        if let id { object["id"] = id }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        // A closed stdout (the shell has gone) must not crash the helper; FileHandle.write(_:)
        // traps on a broken pipe on Windows.
        lock.withLock { try? FileHandle.standardOutput.write(contentsOf: data + Data("\n".utf8)) }
    }
    func log(_ message: String) { try? FileHandle.standardError.write(contentsOf: Data("helper: \(message)\n".utf8)) }
}

actor Helper {
    let out: Output
    var ssoRegion = ""
    var region = ""
    var accountId = ""
    var roleName = ""
    var clientId = ""
    var clientSecret = ""
    var accessToken = ""
    var refreshToken: String?
    var credentials: AWSCredentialSet?
    var plugin: Process?
    var action: Task<Void, Never>?

    init(out: Output) { self.out = out }

    /// Starts a command as the action in progress, unless one is already running.
    func start(_ command: [String: Any]) {
        let id = command["id"] as? String
        if action != nil {
            out.emit(id, "failed", ["error": "busy: another action is in progress"])
            return
        }
        action = Task { await self.handle(command) }
    }

    /// Reports an action's final event. The action is cleared first, so a command sent as soon
    /// as this event is read is never refused as busy.
    private func done(_ id: String?, _ event: String, _ fields: [String: Any] = [:]) {
        action = nil
        out.emit(id, event, fields)
    }

    /// Cancels the action in progress; the action itself reports "cancelled".
    func cancel(_ id: String?) {
        guard let action else {
            out.emit(id, "failed", ["error": "nothing to cancel"])
            return
        }
        // Reported before cancelling, so it always precedes the action's "cancelled".
        out.emit(id, "cancelling")
        action.cancel()
    }

    /// Cancels any action, waits for it to end, and ends any plugin process.
    func shutdown() async {
        let running = action
        running?.cancel()
        await running?.value
        stopPlugin()
    }

    func handle(_ command: [String: Any]) async {
        let id = command["id"] as? String
        let name = command["cmd"] as? String ?? ""
        do {
            switch name {
            case "signIn": try await signIn(id, command)
            case "refresh": try await refresh(id)
            case "identity": try await identity(id)
            case "describe": try await describe(id, command)
            case "tunnel": try await tunnel(id, command)
            case "stop": stopPlugin(); done(id, "stopped")
            default: done(id, "failed", ["error": "unknown command \(name)"])
            }
        } catch let error as AWSServiceError {
            done(id, "failed", ["typeName": error.typeName ?? "", "message": error.message ?? "", "httpStatus": error.httpStatus ?? 0])
        } catch where Self.isCancellation(error) {
            done(id, "cancelled", ["pluginRunning": plugin?.isRunning ?? false])
        } catch {
            done(id, "failed", ["error": String(describing: error)])
        }
    }

    static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }

    private func string(_ command: [String: Any], _ key: String) throws -> String {
        guard let value = command[key] as? String, !value.isEmpty else { throw HelperError.missing(key) }
        return value
    }

    func signIn(_ id: String?, _ command: [String: Any]) async throws {
        ssoRegion = try string(command, "ssoRegion")
        region = try string(command, "region")
        accountId = try string(command, "accountId")
        roleName = try string(command, "roleName")
        let startUrl = try string(command, "startUrl")
        guard AWSRegion.isValid(ssoRegion), AWSRegion.isValid(region) else { throw HelperError.invalidRegion }
        let oidc = AWSClient(region: ssoRegion, credentials: nil)
        let registration = try await oidc.registerClient(clientName: "SSM Connect", clientType: "public", scopes: ["sso:account:access"])
        clientId = registration.clientId
        clientSecret = registration.clientSecret
        let authorization = try await oidc.startDeviceAuthorization(clientId: clientId, clientSecret: clientSecret, startUrl: startUrl)
        out.emit(id, "verify", ["url": authorization.verificationUriComplete ?? "", "userCode": authorization.userCode ?? "",
                                "expiresIn": authorization.expiresIn])
        var interval = max(authorization.interval, 1)
        let deadline = Date().addingTimeInterval(TimeInterval(authorization.expiresIn))
        while Date() < deadline {
            try await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            do {
                let token = try await oidc.createToken(clientId: clientId, clientSecret: clientSecret,
                                                       grantType: "urn:ietf:params:oauth:grant-type:device_code",
                                                       deviceCode: authorization.deviceCode)
                accessToken = token.accessToken
                refreshToken = token.refreshToken
                try await roleCredentials()
                done(id, "signedIn", ["tokenExpiresIn": token.expiresIn, "canRefresh": token.refreshToken != nil])
                return
            } catch let error as AWSServiceError where error.typeName == "AuthorizationPendingException" {
                continue
            } catch let error as AWSServiceError where error.typeName == "SlowDownException" {
                interval += 5
            }
        }
        throw HelperError.deviceAuthorizationTimedOut
    }

    func refresh(_ id: String?) async throws {
        guard let refreshToken else { throw HelperError.cannotRefresh }
        let token = try await AWSClient(region: ssoRegion, credentials: nil)
            .createToken(clientId: clientId, clientSecret: clientSecret, grantType: "refresh_token", refreshToken: refreshToken)
        accessToken = token.accessToken
        self.refreshToken = token.refreshToken ?? refreshToken
        try await roleCredentials()
        done(id, "refreshed", ["tokenExpiresIn": token.expiresIn])
    }

    private func roleCredentials() async throws {
        let role = try await AWSClient(region: ssoRegion, credentials: nil)
            .getRoleCredentials(accessToken: accessToken, accountId: accountId, roleName: roleName)
        credentials = AWSCredentialSet(accessKeyID: role.accessKeyId, secretAccessKey: role.secretAccessKey, sessionToken: role.sessionToken)
    }

    private func client() throws -> AWSClient {
        guard let credentials else { throw HelperError.notSignedIn }
        return AWSClient(region: region, credentials: credentials)
    }

    func identity(_ id: String?) async throws {
        let arn = try await client().getCallerIdentityARN()
        done(id, "identity", ["arn": arn, "username": (try? IdentityMapper.username(fromARN: arn)) ?? ""])
    }

    func describe(_ id: String?, _ command: [String: Any]) async throws {
        let instances = try await client().describeInstances(filters: [
            ("tag:\(try string(command, "tagKey"))", [try string(command, "tagValue")]),
            ("instance-state-name", ["pending", "running", "stopping", "stopped"]),
        ])
        done(id, "instances", ["instances": instances.map { ["instanceId": $0.instanceId, "state": $0.state ?? ""] }])
    }

    func tunnel(_ id: String?, _ command: [String: Any]) async throws {
        let instanceId = try string(command, "instanceId")
        let pluginPath = try string(command, "pluginPath")
        guard let remotePort = command["remotePort"] as? Int, let localPort = command["localPort"] as? Int else { throw HelperError.missing("ports") }
        stopPlugin()
        try Task.checkCancellation()
        let start = try await client().startSession(target: instanceId, documentName: "AWS-StartPortForwardingSession",
                                                    parameters: ["portNumber": [String(remotePort)], "localPortNumber": [String(localPort)]])
        let session = SSMSessionResponse(sessionId: start.sessionId, streamUrl: start.streamUrl, tokenValue: start.tokenValue)
        // The argument contract of BundledPluginTunnel.pluginArguments in the app.
        let parameters: [String: Any] = [
            "Target": instanceId,
            "DocumentName": "AWS-StartPortForwardingSession",
            "Parameters": ["portNumber": [String(remotePort)], "localPortNumber": [String(localPort)]],
        ]
        let parameterJSON = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pluginPath)
        process.arguments = [try session.pluginSessionJSON(), region, "StartSession", "", parameterJSON]
        process.standardOutput = FileHandle.standardError
        process.standardError = FileHandle.standardError
        process.standardInput = FileHandle.nullDevice
        try Task.checkCancellation()
        try process.run()
        plugin = process
        out.emit(id, "pluginStarted", ["sessionId": start.sessionId, "pid": Int(process.processIdentifier)])
        // A failure or cancellation before the tunnel is ready ends the plugin this action started.
        do {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw HelperError.pluginExited(Int(process.terminationStatus)) }
                if await Self.portAccepts(localPort) {
                    try Task.checkCancellation()
                    done(id, "tunnelReady", ["localPort": localPort])
                    return
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw HelperError.tunnelTimedOut
        } catch {
            stopPlugin()
            throw error
        }
    }

    /// The forwarded port is ready when a TCP connection to it on 127.0.0.1 is accepted.
    static func portAccepts(_ port: Int) async -> Bool {
        tcpConnects(port: UInt16(port))
    }

    func stopPlugin() {
        guard let plugin, plugin.isRunning else { self.plugin = nil; return }
        plugin.terminate()
        plugin.waitUntilExit()
        self.plugin = nil
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
    #else
    let handle = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    guard handle >= 0 else { return false }
    defer { close(handle) }
    #endif
    var address = sockaddr_in()
    address.sin_port = port.bigEndian
    #if os(Windows)
    address.sin_family = ADDRESS_FAMILY(AF_INET)
    address.sin_addr.S_un.S_addr = UInt32(0x7F00_0001).bigEndian
    let length = Int32(MemoryLayout<sockaddr_in>.size)
    #else
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
    let length = socklen_t(MemoryLayout<sockaddr_in>.size)
    #endif
    let result = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(handle, $0, length) }
    }
    return result == 0
}

enum HelperError: Error {
    case missing(String), invalidRegion, notSignedIn, cannotRefresh, deviceAuthorizationTimedOut
    case pluginExited(Int), tunnelTimedOut
}

let output = Output()
let helper = Helper(out: output)
output.emit(nil, "ready", ["protocol": 1])
// Standard input is read on its own thread, so a blocking read never holds up the main actor
// while an action runs. It reads through FileHandle rather than readLine(): a thread blocked in
// readLine() holds the stdio lock on stdin, and exit() waits for that lock while flushing
// streams, so the helper would hang on quit.
let lines = AsyncStream<String> { continuation in
    Thread.detachNewThread {
        var buffer = Data()
        func yieldLine(_ bytes: Data) {
            var line = String(decoding: bytes, as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            continuation.yield(line)
        }
        while true {
            let chunk = FileHandle.standardInput.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                yieldLine(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        if !buffer.isEmpty { yieldLine(buffer) }
        continuation.finish()
    }
}
for await line in lines {
    guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        output.emit(nil, "failed", ["error": "not a JSON object"])
        continue
    }
    switch command["cmd"] as? String {
    case "cancel":
        await helper.cancel(command["id"] as? String)
    case "quit":
        await helper.shutdown()
        output.emit(command["id"] as? String, "bye")
        exit(0)
    default:
        await helper.start(command)
    }
}
await helper.shutdown()
output.emit(nil, "bye")
