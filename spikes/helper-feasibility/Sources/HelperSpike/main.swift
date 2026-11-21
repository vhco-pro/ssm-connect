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
//   {"cmd":"quit"} or end of input          ends any plugin process and exits

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

    init(out: Output) { self.out = out }

    func handle(_ command: [String: Any]) async -> Bool {
        let id = command["id"] as? String
        let name = command["cmd"] as? String ?? ""
        do {
            switch name {
            case "signIn": try await signIn(id, command)
            case "refresh": try await refresh(id)
            case "identity": try await identity(id)
            case "describe": try await describe(id, command)
            case "tunnel": try await tunnel(id, command)
            case "stop": stopPlugin(); out.emit(id, "stopped")
            case "quit": stopPlugin(); out.emit(id, "bye"); return false
            default: out.emit(id, "failed", ["error": "unknown command \(name)"])
            }
        } catch let error as AWSServiceError {
            out.emit(id, "failed", ["typeName": error.typeName ?? "", "message": error.message ?? "", "httpStatus": error.httpStatus ?? 0])
        } catch {
            out.emit(id, "failed", ["error": String(describing: error)])
        }
        return true
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
                out.emit(id, "signedIn", ["tokenExpiresIn": token.expiresIn, "canRefresh": token.refreshToken != nil])
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
        out.emit(id, "refreshed", ["tokenExpiresIn": token.expiresIn])
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
        out.emit(id, "identity", ["arn": arn, "username": (try? IdentityMapper.username(fromARN: arn)) ?? ""])
    }

    func describe(_ id: String?, _ command: [String: Any]) async throws {
        let instances = try await client().describeInstances(filters: [
            ("tag:\(try string(command, "tagKey"))", [try string(command, "tagValue")]),
            ("instance-state-name", ["pending", "running", "stopping", "stopped"]),
        ])
        out.emit(id, "instances", ["instances": instances.map { ["instanceId": $0.instanceId, "state": $0.state ?? ""] }])
    }

    func tunnel(_ id: String?, _ command: [String: Any]) async throws {
        let instanceId = try string(command, "instanceId")
        let pluginPath = try string(command, "pluginPath")
        guard let remotePort = command["remotePort"] as? Int, let localPort = command["localPort"] as? Int else { throw HelperError.missing("ports") }
        stopPlugin()
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
        try process.run()
        plugin = process
        out.emit(id, "pluginStarted", ["sessionId": start.sessionId, "pid": Int(process.processIdentifier)])
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            guard process.isRunning else { throw HelperError.pluginExited(Int(process.terminationStatus)) }
            if await Self.portAccepts(localPort) {
                out.emit(id, "tunnelReady", ["localPort": localPort])
                return
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        stopPlugin()
        throw HelperError.tunnelTimedOut
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
while let line = readLine() {
    guard let data = line.data(using: .utf8), let command = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        output.emit(nil, "failed", ["error": "not a JSON object"])
        continue
    }
    if await helper.handle(command) == false { exit(0) }
}
await helper.stopPlugin()
output.emit(nil, "bye")
