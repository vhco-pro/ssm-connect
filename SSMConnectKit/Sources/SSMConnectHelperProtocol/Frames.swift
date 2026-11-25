import Foundation

/// The protocol version a shell and helper must share.
package let helperProtocolVersion = 1

/// A typed failure a shell can act on: a stable code and a user-facing message.
package struct HelperError: Error, Equatable, Sendable, LocalizedError {
    package let code: String
    package let message: String
    package init(code: String, message: String) {
        self.code = code
        self.message = message
    }
    package var errorDescription: String? { message }
}

/// How an admitted command ended. Every admitted command gets exactly one.
package enum Outcome: Equatable, Sendable {
    case completed([String: String])
    case failed(HelperError)
    case cancelled
}

/// One message on either pipe.
package enum Frame: Equatable, Sendable {
    // Shell to helper.
    case hello(build: String, protocolVersion: Int)
    case command(id: String, name: String, arguments: [String: String])
    case cancel(id: String)
    case shutdown
    // Helper to shell.
    case welcome(build: String)
    case refused(reason: String, detail: String)
    case accepted(id: String)
    case rejected(id: String, error: HelperError)
    case result(id: String, outcome: Outcome)
    case event(sequence: Int, workflow: String, name: String, fields: [String: String])
    // Both directions: the shell asks, the helper answers with the same sequence.
    case heartbeat(sequence: Int)
}

package enum FrameError: Error, Equatable {
    case tooLong
    case malformed
}

/// Frames are UTF-8 JSON objects, one per line, each with a `type`.
package enum FrameCodec {
    /// The frame as one line, ending in "\n".
    package static func encode(_ frame: Frame) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object(frame), options: [.sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

    /// Decodes one line without its line ending.
    package static func decode(_ line: Data) throws -> Frame {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = object["type"] as? String else { throw FrameError.malformed }
        func string(_ key: String) throws -> String {
            guard let value = object[key] as? String else { throw FrameError.malformed }
            return value
        }
        func int(_ key: String) throws -> Int {
            guard let value = object[key] as? Int else { throw FrameError.malformed }
            return value
        }
        func strings(_ key: String) throws -> [String: String] {
            guard let value = object[key] else { return [:] }
            guard let dictionary = value as? [String: String] else { throw FrameError.malformed }
            return dictionary
        }
        func error(_ key: String) throws -> HelperError {
            guard let value = object[key] as? [String: Any], let code = value["code"] as? String,
                  let message = value["message"] as? String else { throw FrameError.malformed }
            return HelperError(code: code, message: message)
        }
        switch type {
        case "hello": return .hello(build: try string("build"), protocolVersion: try int("protocolVersion"))
        case "command": return .command(id: try string("id"), name: try string("name"), arguments: try strings("arguments"))
        case "cancel": return .cancel(id: try string("id"))
        case "shutdown": return .shutdown
        case "welcome": return .welcome(build: try string("build"))
        case "refused": return .refused(reason: try string("reason"), detail: try string("detail"))
        case "accepted": return .accepted(id: try string("id"))
        case "rejected": return .rejected(id: try string("id"), error: try error("error"))
        case "result":
            switch try string("outcome") {
            case "completed": return .result(id: try string("id"), outcome: .completed(try strings("value")))
            case "failed": return .result(id: try string("id"), outcome: .failed(try error("error")))
            case "cancelled": return .result(id: try string("id"), outcome: .cancelled)
            default: throw FrameError.malformed
            }
        case "event":
            return .event(sequence: try int("sequence"), workflow: try string("workflow"), name: try string("name"),
                          fields: try strings("fields"))
        case "heartbeat": return .heartbeat(sequence: try int("sequence"))
        default: throw FrameError.malformed
        }
    }

    private static func object(_ frame: Frame) -> [String: Any] {
        func error(_ value: HelperError) -> [String: Any] { ["code": value.code, "message": value.message] }
        switch frame {
        case let .hello(build, version): return ["type": "hello", "build": build, "protocolVersion": version]
        case let .command(id, name, arguments): return ["type": "command", "id": id, "name": name, "arguments": arguments]
        case let .cancel(id): return ["type": "cancel", "id": id]
        case .shutdown: return ["type": "shutdown"]
        case let .welcome(build): return ["type": "welcome", "build": build]
        case let .refused(reason, detail): return ["type": "refused", "reason": reason, "detail": detail]
        case let .accepted(id): return ["type": "accepted", "id": id]
        case let .rejected(id, value): return ["type": "rejected", "id": id, "error": error(value)]
        case let .result(id, .completed(value)): return ["type": "result", "id": id, "outcome": "completed", "value": value]
        case let .result(id, .failed(value)): return ["type": "result", "id": id, "outcome": "failed", "error": error(value)]
        case let .result(id, .cancelled): return ["type": "result", "id": id, "outcome": "cancelled"]
        case let .event(sequence, workflow, name, fields):
            return ["type": "event", "sequence": sequence, "workflow": workflow, "name": name, "fields": fields]
        case let .heartbeat(sequence): return ["type": "heartbeat", "sequence": sequence]
        }
    }
}

/// Splits a byte stream into lines. A line longer than `maximumLength` is a framing error.
package struct FrameReader: Sendable {
    package static let maximumLength = 1 << 20
    private var buffer = Data()

    package init() {}

    /// Appends bytes and returns every complete line, without "\n" or a trailing "\r".
    package mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.last == 0x0D { line.removeLast() }
            guard line.count <= Self.maximumLength else { throw FrameError.tooLong }
            lines.append(line)
        }
        guard buffer.count <= Self.maximumLength else { throw FrameError.tooLong }
        return lines
    }
}
