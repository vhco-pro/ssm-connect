import Crypto
import Foundation

/// AWS credentials for signing. The session token is optional, as for long-term keys.
public struct AWSCredentialSet: Sendable, Equatable {
    public let accessKeyID: String
    public let secretAccessKey: String
    public let sessionToken: String?

    public init(accessKeyID: String, secretAccessKey: String, sessionToken: String? = nil) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
    }
}

/// Signature Version 4 signing, in header form (an `Authorization` header) and query
/// form (a presigned URL). It follows the AWS signing test suite: paths are URI-encoded
/// once as given, so callers pass the path as it goes on the wire.
public enum SigV4 {
    public static let algorithm = "AWS4-HMAC-SHA256"

    /// A request to sign. `path` and `query` are as they appear on the wire; `headers`
    /// keep their order, and repeated names are joined with commas in that order.
    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var query: String?
        public var headers: [(String, String)]
        public var body: Data

        public init(method: String, path: String, query: String? = nil, headers: [(String, String)], body: Data = Data()) {
            self.method = method
            self.path = path
            self.query = query
            self.headers = headers
            self.body = body
        }
    }

    public struct Context: Sendable {
        public var region: String
        public var service: String
        public var date: Date
        /// Remove dot segments and repeated slashes from the path before encoding.
        public var normalizePath: Bool
        /// Add and sign an `x-amz-content-sha256` header (header form only).
        public var signBody: Bool
        /// Leave the session token out of the signature and add it afterwards.
        public var omitSessionToken: Bool

        public init(region: String, service: String, date: Date, normalizePath: Bool = true,
                    signBody: Bool = false, omitSessionToken: Bool = false) {
            self.region = region
            self.service = service
            self.date = date
            self.normalizePath = normalizePath
            self.signBody = signBody
            self.omitSessionToken = omitSessionToken
        }
    }

    public struct HeaderResult: Sendable {
        public let canonicalRequest: String
        public let stringToSign: String
        public let signature: String
        public let authorization: String
        /// Headers to add to the request, in order, including `Authorization`.
        public let headers: [(String, String)]
    }

    public struct QueryResult: Sendable {
        public let canonicalRequest: String
        public let stringToSign: String
        public let signature: String
        /// The signed canonical query, without the signature.
        public let canonicalQuery: String
        /// The complete query to send: the canonical query, the signature, and a session
        /// token added after signing when it was omitted from the signature.
        public let signedQuery: String
    }

    // MARK: Header form

    public static func signHeaders(_ request: Request, credentials: AWSCredentialSet, context: Context) -> HeaderResult {
        let amzDate = Self.amzDate(context.date)
        let payloadHash = hexSHA256(request.body)
        var signed = request.headers
        signed.append(("X-Amz-Date", amzDate))
        var after: [(String, String)] = []
        if let token = credentials.sessionToken, !token.isEmpty {
            if context.omitSessionToken { after.append(("X-Amz-Security-Token", token)) }
            else { signed.append(("X-Amz-Security-Token", token)) }
        }
        if context.signBody { signed.append(("X-Amz-Content-Sha256", payloadHash)) }

        let (canonicalHeaders, signedHeaders) = canonicalize(headers: signed)
        let canonicalRequest = [
            request.method,
            canonicalURI(request.path, normalize: context.normalizePath),
            canonicalQueryString(parse(query: request.query)),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let scope = credentialScope(context)
        let stringToSign = [algorithm, amzDate, scope, hexSHA256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = sign(stringToSign, secret: credentials.secretAccessKey, context: context)
        let authorization = "\(algorithm) Credential=\(credentials.accessKeyID)/\(scope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"
        let added = Array(signed.dropFirst(request.headers.count)) + after + [("Authorization", authorization)]
        return HeaderResult(canonicalRequest: canonicalRequest, stringToSign: stringToSign,
                            signature: signature, authorization: authorization, headers: added)
    }

    // MARK: Query form

    public static func presign(_ request: Request, credentials: AWSCredentialSet, context: Context, expires: Int) -> QueryResult {
        let amzDate = Self.amzDate(context.date)
        let scope = credentialScope(context)
        let (canonicalHeaders, signedHeaders) = canonicalize(headers: request.headers)
        var params = parse(query: request.query)
        params.append(("X-Amz-Algorithm", algorithm))
        params.append(("X-Amz-Credential", "\(credentials.accessKeyID)/\(scope)"))
        params.append(("X-Amz-Date", amzDate))
        params.append(("X-Amz-Expires", String(expires)))
        params.append(("X-Amz-SignedHeaders", signedHeaders))
        var tokenAfter: String?
        if let token = credentials.sessionToken, !token.isEmpty {
            if context.omitSessionToken { tokenAfter = token } else { params.append(("X-Amz-Security-Token", token)) }
        }
        let canonicalQuery = canonicalQueryString(params)
        let canonicalRequest = [
            request.method,
            canonicalURI(request.path, normalize: context.normalizePath),
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            hexSHA256(request.body),
        ].joined(separator: "\n")
        let stringToSign = [algorithm, amzDate, scope, hexSHA256(Data(canonicalRequest.utf8))].joined(separator: "\n")
        let signature = sign(stringToSign, secret: credentials.secretAccessKey, context: context)
        var signedQuery = canonicalQuery + "&X-Amz-Signature=" + signature
        if let tokenAfter { signedQuery += "&X-Amz-Security-Token=" + uriEncode(tokenAfter, encodeSlash: true) }
        return QueryResult(canonicalRequest: canonicalRequest, stringToSign: stringToSign, signature: signature,
                           canonicalQuery: canonicalQuery, signedQuery: signedQuery)
    }

    // MARK: Canonical parts

    static func credentialScope(_ context: Context) -> String {
        "\(dateStamp(context.date))/\(context.region)/\(context.service)/aws4_request"
    }

    /// Lowercased names sorted, values trimmed with internal whitespace runs folded to
    /// one space, repeated names joined with commas in request order.
    static func canonicalize(headers: [(String, String)]) -> (canonical: String, signed: String) {
        var order: [String] = []
        var values: [String: [String]] = [:]
        for (name, value) in headers {
            let key = name.lowercased()
            if values[key] == nil { order.append(key) }
            values[key, default: []].append(foldWhitespace(value))
        }
        let names = order.sorted()
        let canonical = names.map { "\($0):\(values[$0]!.joined(separator: ","))\n" }.joined()
        return (canonical, names.joined(separator: ";"))
    }

    static func foldWhitespace(_ value: String) -> String {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    static func canonicalURI(_ path: String, normalize: Bool) -> String {
        let source = path.isEmpty ? "/" : path
        let effective = normalize ? normalizedPath(source) : source
        return uriEncode(effective, encodeSlash: false)
    }

    /// RFC 3986 dot-segment removal plus collapsing empty segments, keeping a trailing slash.
    static func normalizedPath(_ path: String) -> String {
        var output: [Substring] = []
        let segments = path.split(separator: "/", omittingEmptySubsequences: true)
        for segment in segments {
            switch segment {
            case ".": continue
            case "..": if !output.isEmpty { output.removeLast() }
            default: output.append(segment)
            }
        }
        var result = "/" + output.joined(separator: "/")
        let endsInDirectory = path.hasSuffix("/") || segments.last == "." || segments.last == ".."
        if endsInDirectory && !output.isEmpty { result += "/" }
        return result
    }

    /// Decodes a raw query into pairs; a parameter without `=` has an empty value.
    static func parse(query: String?) -> [(String, String)] {
        guard let query, !query.isEmpty else { return [] }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(parts[0])
            let value = parts.count > 1 ? String(parts[1]) : ""
            return (key.removingPercentEncoding ?? key, value.removingPercentEncoding ?? value)
        }
    }

    /// Pairs encoded, then sorted by encoded name and value.
    static func canonicalQueryString(_ params: [(String, String)]) -> String {
        let encoded: [(name: String, value: String)] = params.map { pair in
            (uriEncode(pair.0, encodeSlash: true), uriEncode(pair.1, encodeSlash: true))
        }
        let sorted = encoded.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.value < rhs.value : lhs.name < rhs.name
        }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    /// Percent-encodes every byte except unreserved characters (and `/` when kept).
    static func uriEncode(_ value: String, encodeSlash: Bool) -> String {
        var out = ""
        for byte in value.utf8 {
            if isUnreserved(byte) || (byte == slash && !encodeSlash) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else {
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static let slash = UInt8(ascii: "/")
    private static let unreservedPunctuation: Set<UInt8> = [UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~")]

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        let isUpper = byte >= 0x41 && byte <= 0x5A
        let isLower = byte >= 0x61 && byte <= 0x7A
        let isDigit = byte >= 0x30 && byte <= 0x39
        return isUpper || isLower || isDigit || unreservedPunctuation.contains(byte)
    }

    // MARK: Crypto and dates

    static func sign(_ stringToSign: String, secret: String, context: Context) -> String {
        let kDate = hmac(key: Data("AWS4\(secret)".utf8), Data(dateStamp(context.date).utf8))
        let kRegion = hmac(key: kDate, Data(context.region.utf8))
        let kService = hmac(key: kRegion, Data(context.service.utf8))
        let kSigning = hmac(key: kService, Data("aws4_request".utf8))
        return hex(hmac(key: kSigning, Data(stringToSign.utf8)))
    }

    static func hmac(key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static func hexSHA256(_ data: Data) -> String { hex(Data(SHA256.hash(data: data))) }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func amzDate(_ date: Date) -> String { format(date, "yyyyMMdd'T'HHmmss'Z'") }

    static func dateStamp(_ date: Date) -> String { format(date, "yyyyMMdd") }

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
