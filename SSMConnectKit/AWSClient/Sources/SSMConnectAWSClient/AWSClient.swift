import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct RegisteredClient: Sendable, Equatable {
    public let clientId: String
    public let clientSecret: String
    public let clientSecretExpiresAt: Int
}

public struct DeviceAuthorization: Sendable, Equatable {
    public let deviceCode: String
    public let userCode: String?
    public let verificationUriComplete: String?
    public let expiresIn: Int
    public let interval: Int
}

public struct SSOToken: Sendable, Equatable {
    public let accessToken: String
    public let expiresIn: Int
    public let refreshToken: String?
}

public struct RoleCredentials: Sendable, Equatable {
    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String
    /// SSO returns expiration as epoch milliseconds.
    public let expirationMilliseconds: Int
}

public struct InstanceSummary: Sendable, Equatable {
    public let instanceId: String
    public let state: String?
    public let privateIpAddress: String?
}

public struct InstanceInformation: Sendable, Equatable {
    public let instanceId: String?
    public let pingStatus: String?
}

public struct SessionStart: Sendable, Equatable {
    public let sessionId: String
    public let streamUrl: String
    public let tokenValue: String
}

/// SSM Connect's AWS client: the 12 requests the app makes, on every platform, with the
/// endpoints, retries and errors of aws-sdk-swift 1.7.62 and nothing configured
/// (cross-platform-client spec, "AWS client"). SSO OIDC and SSO requests are unsigned,
/// as in the SDK; the rest are signed with Signature Version 4.
public struct AWSClient: Sendable {
    public let region: String
    public let credentials: AWSCredentialSet?
    let transport: any HTTPTransport
    let now: @Sendable () -> Date
    let retry: RetryPolicy
    let clockSkew: ClockSkewStore
    let quotas = RetryQuotas()

    /// `clockSkew` is the process-wide store unless a test supplies its own. Each client holds
    /// its own retry quotas, so code that reuses one client shares them across calls.
    public init(region: String, credentials: AWSCredentialSet?, transport: any HTTPTransport = URLSessionTransport(),
                now: @escaping @Sendable () -> Date = { Date() }, retry: RetryPolicy = .standard,
                clockSkew: ClockSkewStore = .shared) {
        self.region = region
        self.credentials = credentials
        self.transport = transport
        self.now = now
        self.retry = retry
        self.clockSkew = clockSkew
    }

    // MARK: SSO OIDC (REST JSON, unsigned)

    public func registerClient(clientName: String, clientType: String, scopes: [String]) async throws -> RegisteredClient {
        let body = try await restJSON(.ssoOIDC, "RegisterClient", path: "/client/register",
                                      ["clientName": clientName, "clientType": clientType, "scopes": scopes])
        guard let id = body["clientId"] as? String, let secret = body["clientSecret"] as? String else {
            throw AWSClientError.malformedResponse(operation: "RegisterClient")
        }
        return RegisteredClient(clientId: id, clientSecret: secret, clientSecretExpiresAt: Self.int(body["clientSecretExpiresAt"]) ?? 0)
    }

    public func startDeviceAuthorization(clientId: String, clientSecret: String, startUrl: String) async throws -> DeviceAuthorization {
        let body = try await restJSON(.ssoOIDC, "StartDeviceAuthorization", path: "/device_authorization",
                                      ["clientId": clientId, "clientSecret": clientSecret, "startUrl": startUrl])
        guard let code = body["deviceCode"] as? String else { throw AWSClientError.malformedResponse(operation: "StartDeviceAuthorization") }
        return DeviceAuthorization(deviceCode: code, userCode: body["userCode"] as? String,
                                   verificationUriComplete: body["verificationUriComplete"] as? String,
                                   expiresIn: Self.int(body["expiresIn"]) ?? 0, interval: Self.int(body["interval"]) ?? 0)
    }

    public func createToken(clientId: String, clientSecret: String, grantType: String,
                            deviceCode: String? = nil, refreshToken: String? = nil) async throws -> SSOToken {
        var input: [String: Any] = ["clientId": clientId, "clientSecret": clientSecret, "grantType": grantType]
        if let deviceCode { input["deviceCode"] = deviceCode }
        if let refreshToken { input["refreshToken"] = refreshToken }
        let body = try await restJSON(.ssoOIDC, "CreateToken", path: "/token", input)
        guard let token = body["accessToken"] as? String else { throw AWSClientError.malformedResponse(operation: "CreateToken") }
        return SSOToken(accessToken: token, expiresIn: Self.int(body["expiresIn"]) ?? 0, refreshToken: body["refreshToken"] as? String)
    }

    // MARK: SSO (REST JSON, bearer token)

    public func getRoleCredentials(accessToken: String, accountId: String, roleName: String) async throws -> RoleCredentials {
        var components = URLComponents(url: try AWSEndpoints.url(for: .sso, region: region), resolvingAgainstBaseURL: false)!
        components.path = "/federation/credentials"
        components.percentEncodedQuery = "account_id=\(SigV4.uriEncode(accountId, encodeSlash: true))&role_name=\(SigV4.uriEncode(roleName, encodeSlash: true))"
        let request = HTTPRequest(method: "GET", url: components.url!, headers: [("x-amz-sso_bearer_token", accessToken)])
        let response = try await send(.sso, url: request.url, signed: false, { _ in request }, decodeError: ErrorDecoding.restJSON)
        let body = ErrorDecoding.jsonObject(response.body)
        guard let role = body["roleCredentials"] as? [String: Any], let key = role["accessKeyId"] as? String,
              let secret = role["secretAccessKey"] as? String, let token = role["sessionToken"] as? String else {
            throw AWSClientError.malformedResponse(operation: "GetRoleCredentials")
        }
        return RoleCredentials(accessKeyId: key, secretAccessKey: secret, sessionToken: token,
                               expirationMilliseconds: Self.int(role["expiration"]) ?? 0)
    }

    // MARK: EC2 (Query, signed)

    public func describeInstances(filters: [(String, [String])] = [], instanceIds: [String] = []) async throws -> [InstanceSummary] {
        var params: [(String, String)] = []
        for (index, filter) in filters.enumerated() {
            params.append(("Filter.\(index + 1).Name", filter.0))
            for (valueIndex, value) in filter.1.enumerated() { params.append(("Filter.\(index + 1).Value.\(valueIndex + 1)", value)) }
        }
        for (index, id) in instanceIds.enumerated() { params.append(("InstanceId.\(index + 1)", id)) }
        let root = try await ec2Query("DescribeInstances", params)
        let reservations = root.first("reservationSet")?.all("item") ?? []
        return reservations.flatMap { $0.first("instancesSet")?.all("item") ?? [] }.compactMap { item in
            guard let id = item.first("instanceId")?.text else { return nil }
            return InstanceSummary(instanceId: id, state: item.first("instanceState")?.first("name")?.text,
                                   privateIpAddress: item.first("privateIpAddress")?.text)
        }
    }

    /// Returns the IDs of the instances whose state changed.
    public func startInstances(instanceIds: [String]) async throws -> [String] {
        try await stateChange("StartInstances", instanceIds)
    }

    public func stopInstances(instanceIds: [String]) async throws -> [String] {
        try await stateChange("StopInstances", instanceIds)
    }

    private func stateChange(_ action: String, _ ids: [String]) async throws -> [String] {
        let root = try await ec2Query(action, ids.enumerated().map { ("InstanceId.\($0.offset + 1)", $0.element) })
        return (root.first("instancesSet")?.all("item") ?? []).compactMap { $0.first("instanceId")?.text }
    }

    // MARK: Systems Manager, Secrets Manager, EC2 Instance Connect (AWS JSON 1.1, signed)

    public func describeInstanceInformation(filters: [(String, [String])]) async throws -> [InstanceInformation] {
        let body = try await awsJSON(.ssm, target: "AmazonSSM.DescribeInstanceInformation",
                                     ["Filters": filters.map { ["Key": $0.0, "Values": $0.1] }])
        return (body["InstanceInformationList"] as? [[String: Any]] ?? []).map {
            InstanceInformation(instanceId: $0["InstanceId"] as? String, pingStatus: $0["PingStatus"] as? String)
        }
    }

    public func startSession(target: String, documentName: String, parameters: [String: [String]]) async throws -> SessionStart {
        let body = try await awsJSON(.ssm, target: "AmazonSSM.StartSession",
                                     ["DocumentName": documentName, "Parameters": parameters, "Target": target])
        guard let id = body["SessionId"] as? String, let url = body["StreamUrl"] as? String, let token = body["TokenValue"] as? String else {
            throw AWSClientError.malformedResponse(operation: "StartSession")
        }
        return SessionStart(sessionId: id, streamUrl: url, tokenValue: token)
    }

    public func getSecretValue(secretId: String) async throws -> String? {
        let body = try await awsJSON(.secretsManager, target: "secretsmanager.GetSecretValue", ["SecretId": secretId])
        return body["SecretString"] as? String
    }

    public func sendSSHPublicKey(instanceId: String, instanceOSUser: String, sshPublicKey: String) async throws -> Bool {
        let body = try await awsJSON(.ec2InstanceConnect, target: "AWSEC2InstanceConnectService.SendSSHPublicKey",
                                     ["InstanceId": instanceId, "InstanceOSUser": instanceOSUser, "SSHPublicKey": sshPublicKey])
        return body["Success"] as? Bool ?? false
    }

    // MARK: STS identity (presigned GET, one attempt)

    /// The presigned GetCallerIdentity URL the workstation agent verifies.
    public func presignedCallerIdentityURL(expires: Int = 120) throws -> URL {
        let endpoint = try AWSEndpoints.url(for: .sts, region: region)
        let host = endpoint.host!
        let result = SigV4.presign(
            SigV4.Request(method: "GET", path: "/", query: "Action=GetCallerIdentity&Version=2011-06-15", headers: [("Host", host)]),
            credentials: try requireCredentials(),
            context: SigV4.Context(region: region, service: AWSService.sts.signingName, date: now()),
            expires: expires
        )
        return URL(string: "https://\(host)/?\(result.signedQuery)")!
    }

    /// Sends the presigned GetCallerIdentity request once and returns the caller's ARN.
    public func getCallerIdentityARN() async throws -> String {
        let request = HTTPRequest(method: "GET", url: try presignedCallerIdentityURL())
        let response = try await transport.send(request)
        guard (200..<300).contains(response.status) else { throw AWSClientError.identityRejected(httpStatus: response.status) }
        guard let arn = Self.arn(in: response.body) else { throw AWSClientError.malformedResponse(operation: "GetCallerIdentity") }
        return arn
    }

    static func arn(in data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        guard let open = text.range(of: "<Arn>"), let close = text.range(of: "</Arn>"), open.upperBound <= close.lowerBound else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
    }

    // MARK: Protocols

    private func restJSON(_ service: AWSService, _ operation: String, path: String, _ input: [String: Any]) async throws -> [String: Any] {
        var url = try AWSEndpoints.url(for: service, region: region)
        url.appendPathComponent(String(path.dropFirst()))
        let request = HTTPRequest(method: "POST", url: url, headers: [("Content-Type", "application/json")],
                                  body: try JSONSerialization.data(withJSONObject: input))
        let response = try await send(service, url: url, signed: false, { _ in request }, decodeError: ErrorDecoding.restJSON)
        return ErrorDecoding.jsonObject(response.body)
    }

    private func awsJSON(_ service: AWSService, target: String, _ input: [String: Any]) async throws -> [String: Any] {
        let body = try JSONSerialization.data(withJSONObject: input)
        let url = try AWSEndpoints.url(for: service, region: region)
        let response = try await send(service, url: url, signed: true, { date in
            try self.signed(service, url: url, body: body, date: date,
                            headers: [("Content-Type", "application/x-amz-json-1.1"), ("X-Amz-Target", target)])
        }, decodeError: { ErrorDecoding.awsJSON($0, service: service) })
        return ErrorDecoding.jsonObject(response.body)
    }

    private func ec2Query(_ action: String, _ params: [(String, String)]) async throws -> XMLElement {
        let pairs = params + [("Action", action), ("Version", "2016-11-15")]
        let form = pairs.map { "\(SigV4.uriEncode($0.0, encodeSlash: true))=\(SigV4.uriEncode($0.1, encodeSlash: true))" }.joined(separator: "&")
        let url = try AWSEndpoints.url(for: .ec2, region: region)
        let response = try await send(.ec2, url: url, signed: true, { date in
            try self.signed(.ec2, url: url, body: Data(form.utf8), date: date, headers: [("Content-Type", "application/x-www-form-urlencoded")])
        }, decodeError: ErrorDecoding.ec2)
        guard let root = XMLElement.parse(response.body) else { throw AWSClientError.malformedResponse(operation: action) }
        return root
    }

    /// A POST to the service root, signed in header form at `date`.
    private func signed(_ service: AWSService, url: URL, body: Data, date: Date, headers: [(String, String)]) throws -> HTTPRequest {
        let host = url.port.map { "\(url.host!):\($0)" } ?? url.host!
        let unsigned = [("Host", host)] + headers
        let result = SigV4.signHeaders(
            SigV4.Request(method: "POST", path: "/", headers: unsigned, body: body),
            credentials: try requireCredentials(),
            context: SigV4.Context(region: region, service: service.signingName, date: date)
        )
        return HTTPRequest(method: "POST", url: url, headers: headers + result.headers, body: body)
    }

    private func requireCredentials() throws -> AWSCredentialSet {
        guard let credentials else { throw AWSClientError.malformedResponse(operation: "signing without credentials") }
        return credentials
    }

    /// Sends with the fixed retry policy, the clock-skew correction and the client's retry quota
    /// for `service`. Each attempt rebuilds the request; a signed one is signed at the local time
    /// plus the host's stored offset (`build` receives that time).
    func send(_ service: AWSService, url: URL, signed: Bool, _ build: (Date) throws -> HTTPRequest,
              decodeError: (HTTPResponse) -> AWSServiceError) async throws -> HTTPResponse {
        let host = url.host ?? ""
        var retryCount = 0
        var lastRetryCost: Int?
        while true {
            try Task.checkCancellation()
            let failure: any Error
            let timedOut: Bool
            do {
                let local = now()
                let offset = await clockSkew.offset(host: host) ?? 0
                let response = try await transport.send(try build(local.addingTimeInterval(offset)))
                if (200..<300).contains(response.status) {
                    quotas.release(service.signingName, lastRetryCost: lastRetryCost)
                    return response
                }
                let error = decodeError(response)
                let skewChanged = await clockSkew.update(host: host) { previous in
                    ClockSkew.next(previous: previous, error: error, signedAt: signed ? local : nil, response: response)
                }
                guard skewChanged || RetryPolicy.isRetryable(error) else { throw error }
                failure = error
                timedOut = false
            } catch let error as URLError {
                guard RetryPolicy.isRetryable(error) else { throw error }
                failure = error
                timedOut = error.code == .timedOut
            }
            guard retryCount + 1 < RetryPolicy.maxAttempts else { throw failure }
            guard let cost = quotas.take(service.signingName, timeout: timedOut) else { throw failure }
            lastRetryCost = cost
            try await retry.sleep(RetryPolicy.delay(retry: retryCount, random: retry.random()))
            retryCount += 1
        }
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }
}
