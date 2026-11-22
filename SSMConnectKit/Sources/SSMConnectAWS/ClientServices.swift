import Foundation
import SSMConnectAWSClient
import SSMConnectDomain
import SSMConnectWorkflow

// The service ports on SSM Connect's own AWS client: the AWS implementation on Windows and
// Linux, and on macOS once T36 removes the SDK. Each applies the same rules as the SDK-backed
// service of the same name and, like it, makes one client per call.

extension AWSCredentials {
    /// The credentials in the AWS client's form; an empty session token is omitted.
    package var signingCredentials: AWSCredentialSet {
        AWSCredentialSet(accessKeyID: accessKeyId, secretAccessKey: secretAccessKey,
                         sessionToken: sessionToken.isEmpty ? nil : sessionToken)
    }
}

/// Builds the client for one call.
package struct AWSClientFactory: Sendable {
    package var transport: any HTTPTransport
    package init(transport: any HTTPTransport = URLSessionTransport()) { self.transport = transport }
    package func make(_ credentials: AWSCredentials?, region: String) -> AWSClient {
        AWSClient(region: region, credentials: credentials?.signingCredentials, transport: transport)
    }
}

package struct ClientEC2Service: EC2Providing {
    private let clients: AWSClientFactory
    package init(clients: AWSClientFactory = AWSClientFactory()) { self.clients = clients }

    package func resolveInstance(tagKey: String, tagValue: String, region: String,
                                 credentials: AWSCredentials) async throws -> EC2Instance {
        // F-06: filter by tag + the states a resolvable workstation can be in.
        let instances = try await clients.make(credentials, region: region).describeInstances(filters: [
            ("tag:\(tagKey)", [tagValue]),
            ("instance-state-name", ["pending", "running", "stopping", "stopped"]),
        ])
        guard !instances.isEmpty else { throw EC2Error.noMatchingInstance(tagKey: tagKey, tagValue: tagValue) }
        guard instances.count == 1 else {
            throw EC2Error.multipleMatchingInstances(tagKey: tagKey, tagValue: tagValue, count: instances.count)
        }
        return Self.domain(instances[0])
    }

    package func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        _ = try await clients.make(credentials, region: region).startInstances(instanceIds: [instanceId])
    }

    package func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        _ = try await clients.make(credentials, region: region).stopInstances(instanceIds: [instanceId])
    }

    package func pollUntilRunning(instanceId: String, region: String, credentials: AWSCredentials,
                                  timeout: Duration, interval: Duration) async throws -> EC2Instance {
        let client = clients.make(credentials, region: region)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastState: EC2Instance.State = .pending
        while ContinuousClock.now < deadline {
            guard let summary = try await client.describeInstances(instanceIds: [instanceId]).first else {
                throw EC2Error.noMatchingInstance(tagKey: "instance-id", tagValue: instanceId)
            }
            let instance = Self.domain(summary)
            lastState = instance.state
            switch instance.state {
            case .running: return instance
            case .terminated, .shuttingDown: throw EC2Error.instanceTerminated(instanceId: instanceId)
            case .pending, .stopping, .stopped, .unknown: break
            }
            try await Task.sleep(for: interval)
        }
        // Timed out: distinguish a stuck-pending instance from a generic start timeout (spec §8).
        throw lastState == .pending ? EC2Error.pendingStuck(instanceId: instanceId) : EC2Error.startTimedOut(instanceId: instanceId)
    }

    package static func domain(_ summary: InstanceSummary) -> EC2Instance {
        EC2Instance(id: summary.instanceId, state: summary.state.flatMap(EC2Instance.State.init(rawValue:)) ?? .unknown,
                    privateIpAddress: summary.privateIpAddress)
    }
}

package struct ClientSSMService: SSMProviding {
    private let clients: AWSClientFactory
    package init(clients: AWSClientFactory = AWSClientFactory()) { self.clients = clients }

    package func startSSHSession(instanceId: String, region: String, credentials: AWSCredentials) async throws -> SSMSessionResponse {
        try Self.response(try await Self.start(clients.make(credentials, region: region), target: instanceId,
                                               document: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]]))
    }

    package func waitForSSMOnline(instanceId: String, region: String, credentials: AWSCredentials,
                                  timeout: Duration, interval: Duration) async throws {
        let client = clients.make(credentials, region: region)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            let information = try await client.describeInstanceInformation(filters: [("InstanceIds", [instanceId])])
            if information.contains(where: { $0.instanceId == instanceId && $0.pingStatus == "Online" }) { return }
            try await Task.sleep(for: interval)
        }
        throw SSMError.notOnlineInTime(instanceId: instanceId)
    }

    package func startSession(instanceId: String, region: String, credentials: AWSCredentials,
                              localPort: Int, remotePort: Int) async throws -> SSMSessionResponse {
        try Self.response(try await Self.start(clients.make(credentials, region: region), target: instanceId,
                                               document: "AWS-StartPortForwardingSession",
                                               parameters: ["portNumber": [String(remotePort)], "localPortNumber": [String(localPort)]]))
    }

    /// StartSession through the client: a reply missing a field is malformed, as the SDK service
    /// reported it.
    private static func start(_ client: AWSClient, target: String, document: String,
                              parameters: [String: [String]]) async throws -> SessionStart {
        do { return try await client.startSession(target: target, documentName: document, parameters: parameters) }
        catch AWSClientError.malformedResponse(operation: "StartSession") { throw SSMError.malformedSessionResponse }
    }

    package static func response(_ start: SessionStart) throws -> SSMSessionResponse {
        guard !start.sessionId.isEmpty, !start.streamUrl.isEmpty, !start.tokenValue.isEmpty else {
            throw SSMError.malformedSessionResponse
        }
        return SSMSessionResponse(sessionId: start.sessionId, streamUrl: start.streamUrl, tokenValue: start.tokenValue)
    }
}

package struct ClientSecretsService: SecretsProviding {
    private let clients: AWSClientFactory
    package init(clients: AWSClientFactory = AWSClientFactory()) { self.clients = clients }

    package func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
        let value: String?
        do { value = try await clients.make(credentials, region: region).getSecretValue(secretId: secretId) }
        catch let error as AWSServiceError where error.typeName == "ResourceNotFoundException" {
            throw SecretsError.notFound(secretId: secretId)
        }
        guard let value, !value.isEmpty else { throw SecretsError.empty(secretId: secretId) }
        return value
    }
}

package struct ClientInstanceConnectService: InstanceConnectProviding {
    private let clients: AWSClientFactory
    package init(clients: AWSClientFactory = AWSClientFactory()) { self.clients = clients }

    package func sendPublicKey(instanceId: String, user: String, publicKey: String,
                               region: String, credentials: AWSCredentials) async throws {
        let accepted: Bool
        do {
            accepted = try await clients.make(credentials, region: region)
                .sendSSHPublicKey(instanceId: instanceId, instanceOSUser: user, sshPublicKey: publicKey)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebForwardsError.keyPushFailed
        }
        guard accepted else { throw WebForwardsError.keyPushFailed }
    }
}
