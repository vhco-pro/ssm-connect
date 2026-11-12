import Foundation

struct Request: Decodable {
    let version: Int
    let command: String
    let value: String?
    let config: String?
}

struct Response: Encodable {
    let version = 1
    let event: String
    var valid: Bool?
    var resourceRegion: String?
    var error: String?
}

func emit(_ response: Response) throws {
    FileHandle.standardOutput.write(try JSONEncoder().encode(response))
    FileHandle.standardOutput.write(Data([10]))
}

requests: while let line = readLine() {
    let request: Request
    do {
        request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
    } catch is DecodingError {
        try emit(Response(event: "error", error: "invalid request"))
        continue
    }

    guard request.version == 1 else {
        try emit(Response(event: "error", error: "unsupported protocol version"))
        continue
    }

    switch request.command {
    case "hello":
        try emit(Response(event: "ready"))
    case "region":
        guard let value = request.value else {
            try emit(Response(event: "error", error: "missing region"))
            continue
        }
        try emit(Response(event: "region", valid: AWSRegion.isValid(value)))
    case "profile":
        guard let name = request.value, let config = request.config,
              let region = AWSConfigParser(contents: config)
                .resolvedProfile(named: name)?.resourceRegion else {
            try emit(Response(event: "error", error: "missing profile or resource region"))
            continue
        }
        try emit(Response(event: "profile", resourceRegion: region))
    case "stop":
        try emit(Response(event: "stopped"))
        break requests
    default:
        try emit(Response(event: "error", error: "unknown command"))
    }
}
