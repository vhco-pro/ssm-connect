import Foundation

/// The AWS services the app calls.
public enum AWSService: String, Sendable, CaseIterable {
    case ssoOIDC, sso, ec2, ssm, secretsManager, ec2InstanceConnect, sts

    /// The host label before the region, as each service's endpoint rules write it.
    var hostPrefix: String {
        switch self {
        case .ssoOIDC: "oidc"
        case .sso: "portal.sso"
        case .ec2: "ec2"
        case .ssm: "ssm"
        case .secretsManager: "secretsmanager"
        case .ec2InstanceConnect: "ec2-instance-connect"
        case .sts: "sts"
        }
    }

    /// The service name in a Signature Version 4 credential scope.
    var signingName: String {
        switch self {
        case .ssoOIDC: "sso-oauth"
        case .sso: "awsssoportal"
        case .ec2: "ec2"
        case .ssm: "ssm"
        case .secretsManager: "secretsmanager"
        case .ec2InstanceConnect: "ec2-instance-connect"
        case .sts: "sts"
        }
    }
}

/// Regional endpoint resolution matching the endpoint rules of aws-sdk-swift 1.7.62 for
/// these services without FIPS, dual-stack or an override: `https://<prefix>.<region>.<suffix>`,
/// where the suffix is `amazonaws.com.cn` in the China partition and `amazonaws.com` in
/// the standard and GovCloud partitions. Configured endpoint settings (environment
/// variables and shared config) are never read.
public enum AWSEndpoints {
    public enum ResolveError: Error, Equatable, LocalizedError {
        case invalidRegion(String)

        /// Read as the SDK's invalid-value error read: "Invalid region: <region>".
        public var errorDescription: String? {
            switch self {
            case let .invalidRegion(region): "Invalid region: \(region)"
            }
        }
    }

    public static func dnsSuffix(region: String) -> String {
        region.hasPrefix("cn-") ? "amazonaws.com.cn" : "amazonaws.com"
    }

    public static func url(for service: AWSService, region: String) throws -> URL {
        let valid = !region.isEmpty && region.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            && !region.hasPrefix("-") && !region.hasSuffix("-")
        guard valid, let url = URL(string: "https://\(service.hostPrefix).\(region).\(dnsSuffix(region: region))") else {
            throw ResolveError.invalidRegion(region)
        }
        return url
    }
}
