import Foundation

/// An error an AWS service returned, with the facts the app's translation reads: the
/// error's type name, its message and the HTTP status. They match what aws-sdk-swift
/// 1.7.62 exposes for the same response.
public struct AWSServiceError: Error, Equatable, Sendable, CustomStringConvertible {
    public let typeName: String?
    public let message: String?
    public let httpStatus: Int?
    public let requestID: String?

    public init(typeName: String?, message: String?, httpStatus: Int?, requestID: String? = nil) {
        self.typeName = typeName
        self.message = message
        self.httpStatus = httpStatus
        self.requestID = requestID
    }

    public var description: String {
        let detail = [typeName, httpStatus.map { "HTTP \($0)" }].compactMap { $0 }.joined(separator: ", ")
        return (message ?? typeName ?? "AWS error") + (detail.isEmpty ? "" : " (\(detail))")
    }
}

/// A response the client could not use.
public enum AWSClientError: Error, Equatable, Sendable {
    case malformedResponse(operation: String)
    case identityRejected(httpStatus: Int)
}

enum ErrorDecoding {
    /// Strips a namespace (`com.amazonaws.ssm#X`) and a trailing detail (`X:http://...`).
    static func sanitize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let colon = value.firstIndex(of: ":") { value = String(value[..<colon]) }
        if let hash = value.lastIndex(of: "#") { value = String(value[value.index(after: hash)...]) }
        return value.isEmpty ? nil : value
    }

    static func jsonObject(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    static func message(in body: [String: Any]) -> String? {
        (body["message"] as? String) ?? (body["Message"] as? String)
    }

    /// REST JSON (SSO OIDC, SSO): the type from x-amzn-ErrorType, else the body.
    static func restJSON(_ response: HTTPResponse) -> AWSServiceError {
        let body = jsonObject(response.body)
        let type = sanitize(response.header("x-amzn-ErrorType")) ?? sanitize(body["__type"] as? String) ?? sanitize(body["code"] as? String)
        return AWSServiceError(typeName: type, message: message(in: body), httpStatus: response.status,
                               requestID: response.header("x-amzn-RequestId"))
    }

    /// AWS JSON 1.1 (Systems Manager, Secrets Manager, EC2 Instance Connect): the type
    /// from __type, else x-amzn-ErrorType, renamed where the service model gives an
    /// error a code that differs from its shape name.
    static func awsJSON(_ response: HTTPResponse, service: AWSService) -> AWSServiceError {
        let body = jsonObject(response.body)
        var type = sanitize(body["__type"] as? String) ?? sanitize(response.header("x-amzn-ErrorType"))
        if let shape = type, let code = modeledCodes[service]?[shape] { type = code }
        return AWSServiceError(typeName: type, message: message(in: body), httpStatus: response.status,
                               requestID: response.header("x-amzn-RequestId"))
    }

    /// EC2 Query: `<Errors><Error><Code/><Message/></Error></Errors>`.
    static func ec2(_ response: HTTPResponse) -> AWSServiceError {
        let root = XMLElement.parse(response.body)
        let error = root?.first("Errors")?.first("Error") ?? root?.first("Error")
        return AWSServiceError(typeName: error?.first("Code")?.text, message: error?.first("Message")?.text,
                               httpStatus: response.status,
                               requestID: root?.first("RequestID")?.text ?? root?.first("RequestId")?.text)
    }

    /// Error codes that differ from shape names, from the aws-sdk-swift 1.7.62 models.
    static let modeledCodes: [AWSService: [String: String]] = [
        .ec2InstanceConnect: [
            "AuthException": "Forbidden",
            "EC2InstanceNotFoundException": "EC2InstanceNotFound",
            "EC2InstanceStateInvalidException": "EC2InstanceStateInvalid",
            "EC2InstanceTypeInvalidException": "EC2InstanceTypeInvalid",
            "EC2InstanceUnavailableException": "EC2InstanceUnavailable",
            "InvalidArgsException": "InvalidArguments",
            "SerialConsoleAccessDisabledException": "SerialConsoleAccessDisabled",
            "SerialConsoleSessionLimitExceededException": "SerialConsoleSessionLimitExceeded",
            "SerialConsoleSessionUnavailableException": "SerialConsoleSessionUnavailable",
            "SerialConsoleSessionUnsupportedException": "SerialConsoleSessionUnsupported",
            "ServiceException": "InternalServerError",
            "ThrottlingException": "TooManyRequests",
        ],
    ]
}
