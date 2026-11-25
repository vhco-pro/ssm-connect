import Foundation
import Testing
@testable import SSMConnectAWSClient

/// Signature Version 4 conformance: every case of the AWS signing test suite
/// (Fixtures/sigv4, copied from awslabs/aws-c-auth) signed in header and query
/// mode, plus the STS presign known answer the agent's verifier accepts today.
@Suite("SigV4")
struct SigV4Tests {
    static let suiteURL = Bundle.module.url(forResource: "Fixtures/sigv4", withExtension: nil)!

    static var caseNames: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: suiteURL.path)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(
                atPath: suiteURL.appendingPathComponent(name).path, isDirectory: &isDirectory
            ) && isDirectory.boolValue
        }.sorted()
    }

    @Test("The test suite is present")
    func suitePresent() {
        #expect(Self.caseNames.count == 38)
    }

    @Test("Header signing matches the test suite", arguments: caseNames)
    func headerSigning(_ name: String) throws {
        let vector = try Vector(name: name, directory: Self.suiteURL.appendingPathComponent(name))
        let result = SigV4.signHeaders(vector.request, credentials: vector.credentials, context: vector.context)
        #expect(result.canonicalRequest == vector.text("header-canonical-request.txt"))
        #expect(result.stringToSign == vector.text("header-string-to-sign.txt"))
        #expect(result.signature == vector.text("header-signature.txt"))
        let expected = Vector.parseRequest(vector.text("header-signed-request.txt"))
        let expectedAuthorization = expected.headers.first { $0.0.lowercased() == "authorization" }?.1
        #expect(result.authorization == expectedAuthorization)
    }

    @Test("Query signing matches the test suite", arguments: caseNames)
    func querySigning(_ name: String) throws {
        let vector = try Vector(name: name, directory: Self.suiteURL.appendingPathComponent(name))
        let result = SigV4.presign(
            vector.request, credentials: vector.credentials, context: vector.context, expires: vector.expires
        )
        #expect(result.canonicalRequest == vector.text("query-canonical-request.txt"))
        #expect(result.stringToSign == vector.text("query-string-to-sign.txt"))
        #expect(result.signature == vector.text("query-signature.txt"))
        let expected = Vector.parseRequest(vector.text("query-signed-request.txt"))
        #expect(Vector.queryPairs(result.signedQuery) == Vector.queryPairs(expected.query ?? ""))
    }

    /// The presigned GetCallerIdentity URL the app mints today (STSPresignerTests in the
    /// main package), reproduced by the shared signer.
    @Test("STS presign matches the current known answer")
    func stsKnownAnswer() {
        let request = SigV4.Request(
            method: "GET", path: "/", query: "Action=GetCallerIdentity&Version=2011-06-15",
            headers: [("Host", "sts.eu-central-1.amazonaws.com")], body: Data()
        )
        let credentials = AWSCredentialSet(
            accessKeyID: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "SESSIONTOKEN123"
        )
        let context = SigV4.Context(
            region: "eu-central-1", service: "sts", date: Date(timeIntervalSince1970: 1_781_352_000)
        )
        let result = SigV4.presign(request, credentials: credentials, context: context, expires: 120)
        let url = "https://sts.eu-central-1.amazonaws.com/?" + result.canonicalQuery
            + "&X-Amz-Signature=" + result.signature
        #expect(url == "https://sts.eu-central-1.amazonaws.com/?"
            + "Action=GetCallerIdentity&Version=2011-06-15"
            + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIDEXAMPLE%2F20260613%2Feu-central-1%2Fsts%2Faws4_request"
            + "&X-Amz-Date=20260613T120000Z&X-Amz-Expires=120"
            + "&X-Amz-Security-Token=SESSIONTOKEN123&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=72867d630efb3316185feb18215d315ab7e98ea73a7823946a3b07e755ac8aa2")
    }
}

/// One test-suite case: its request, context and expected outputs.
struct Vector {
    let directory: URL
    let request: SigV4.Request
    let credentials: AWSCredentialSet
    let context: SigV4.Context
    let expires: Int

    init(name: String, directory: URL) throws {
        self.directory = directory
        let json = try JSONSerialization.jsonObject(
            with: Data(contentsOf: directory.appendingPathComponent("context.json"))
        ) as! [String: Any]
        let creds = json["credentials"] as! [String: Any]
        credentials = AWSCredentialSet(
            accessKeyID: creds["access_key_id"] as! String,
            secretAccessKey: creds["secret_access_key"] as! String,
            sessionToken: creds["token"] as? String
        )
        let formatter = ISO8601DateFormatter()
        context = SigV4.Context(
            region: json["region"] as! String,
            service: json["service"] as! String,
            date: formatter.date(from: json["timestamp"] as! String)!,
            normalizePath: json["normalize"] as! Bool,
            signBody: json["sign_body"] as! Bool,
            omitSessionToken: json["omit_session_token"] as? Bool ?? false
        )
        expires = json["expiration_in_seconds"] as! Int
        let raw = String(decoding: try Data(contentsOf: directory.appendingPathComponent("request.txt")), as: UTF8.self)
        request = Self.parseRequest(raw)
    }

    func text(_ file: String) -> String {
        String(decoding: (try? Data(contentsOf: directory.appendingPathComponent(file))) ?? Data(), as: UTF8.self)
    }

    /// Parses the suite's raw HTTP request format. Header continuation lines (leading
    /// whitespace) join the previous header with a newline, as the suite expects.
    static func parseRequest(_ raw: String) -> SigV4.Request {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n\n")
        let head = parts[0]
        let body = parts.count > 1 ? parts.dropFirst().joined(separator: "\n\n") : ""
        var lines = head.components(separatedBy: "\n")
        let requestLine = lines.removeFirst()
        let tokens = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let method = tokens.first!
        let target = tokens.dropFirst().dropLast().joined(separator: " ")
        let (path, query): (String, String?) = {
            guard let mark = target.firstIndex(of: "?") else { return (target, nil) }
            return (String(target[..<mark]), String(target[target.index(after: mark)...]))
        }()
        var headers: [(String, String)] = []
        for line in lines where !line.isEmpty {
            if line.first == " " || line.first == "\t", let last = headers.popLast() {
                headers.append((last.0, last.1 + "\n" + line))
            } else if let colon = line.firstIndex(of: ":") {
                headers.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
            }
        }
        return SigV4.Request(method: method, path: path, query: query, headers: headers, body: Data(body.utf8))
    }

    /// Decoded query pairs, sorted, so differently ordered but equal queries compare equal.
    static func queryPairs(_ query: String) -> [String] {
        query.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            return key + "=" + value
        }.sorted()
    }
}
