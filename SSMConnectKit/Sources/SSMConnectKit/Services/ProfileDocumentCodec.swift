import CYaml
import Foundation
import Yams

enum ProfileDocumentCodec {
    static let maximumBytes = 256 * 1024
    static let maximumDepth = 32
    static let maximumNodes = 8192

    static func read(_ data: Data, format: ProfileFileFormat) throws -> PortableProfileDocument {
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw PortableProfileError.invalid("Profile files must be UTF-8 and at most 256 KiB.")
        }
        try checkEvents(data)
        if format == .json {
            do { _ = try JSONSerialization.jsonObject(with: data) }
            catch { throw PortableProfileError.invalid("This profile is not valid JSON.") }
        }
        let root: Node
        do {
            guard let node = try Yams.Parser(yaml: text, resolver: .basic).singleRoot() else {
                throw PortableProfileError.invalid("The profile file is empty.")
            }
            root = node
        } catch let error as PortableProfileError { throw error }
        catch { throw PortableProfileError.invalid("Invalid YAML or duplicate mapping keys. Review the profile file.") }
        guard case let .object(fields) = try value(root) else {
            throw PortableProfileError.invalid("A profile file must contain one mapping, not a list of profiles.")
        }
        return try PortableProfileDocument(fields: fields)
    }

    static func write(_ document: PortableProfileDocument, format: ProfileFileFormat) throws -> Data {
        _ = try document.profile(localID: UUID())
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(document.fields) + Data("\n".utf8)
        case .yaml:
            data = Data(try Yams.serialize(node: node(.object(document.fields)), indent: 2, width: -1,
                                           allowUnicode: true, sortKeys: true).utf8)
        }
        guard data.count <= maximumBytes else {
            throw PortableProfileError.invalid("The canonical profile exceeds the 256 KiB file limit.")
        }
        return data
    }

    // Yams' tree parser is recursive. Check libyaml events before constructing that tree.
    private static func checkEvents(_ data: Data) throws {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else {
            throw PortableProfileError.invalid("The YAML parser could not be initialized.")
        }
        defer { yaml_parser_delete(&parser) }
        try data.withUnsafeBytes { bytes in
            yaml_parser_set_input_string(&parser, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            var depth = 0
            var nodes = 0
            var documents = 0
            while true {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) == 1 else {
                    throw PortableProfileError.invalid("Invalid profile syntax near line \(parser.problem_mark.line + 1), column \(parser.problem_mark.column + 1).")
                }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_STREAM_END_EVENT: return
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                    guard documents == 1 else { throw PortableProfileError.invalid("Use exactly one profile document per file.") }
                case YAML_ALIAS_EVENT:
                    throw PortableProfileError.invalid("YAML anchors, aliases and merges are not supported in portable profiles.")
                case YAML_SCALAR_EVENT:
                    nodes += 1
                    guard event.data.scalar.anchor == nil, event.data.scalar.tag == nil else {
                        throw PortableProfileError.invalid("Explicit YAML tags and anchors are not supported.")
                    }
                case YAML_MAPPING_START_EVENT, YAML_SEQUENCE_START_EVENT:
                    nodes += 1
                    depth += 1
                    let safe = event.type == YAML_MAPPING_START_EVENT
                        ? event.data.mapping_start.anchor == nil && event.data.mapping_start.tag == nil
                        : event.data.sequence_start.anchor == nil && event.data.sequence_start.tag == nil
                    guard safe else { throw PortableProfileError.invalid("Explicit YAML tags and anchors are not supported.") }
                case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT: depth -= 1
                default: break
                }
                guard depth <= maximumDepth, nodes <= maximumNodes else {
                    throw PortableProfileError.invalid("Profile files are limited to depth 32 and 8192 nodes.")
                }
            }
        }
    }

    private static func value(_ node: Node) throws -> ProfileValue {
        switch node {
        case let .mapping(mapping):
            var object: [String: ProfileValue] = [:]
            for (key, child) in mapping {
                guard case let .scalar(scalar) = key, scalar.string != "<<", object[scalar.string] == nil else {
                    throw PortableProfileError.invalid("Profile mappings need unique string keys; YAML merges are not supported.")
                }
                object[scalar.string] = try value(child)
            }
            return .object(object)
        case let .sequence(sequence): return .array(try sequence.map(value))
        case let .scalar(scalar):
            let text = scalar.string
            if scalar.style != .plain { return .string(text) }
            if text == "true" { return .bool(true) }
            if text == "false" { return .bool(false) }
            if text == "null" || text == "~" || text.isEmpty { return .null }
            if text.range(of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil {
                let parts = text.split(whereSeparator: { $0 == "e" || $0 == "E" })
                let exponent = parts.count == 2 ? Int(parts[1]) : 0
                guard let exponent, (-128...127).contains(exponent) else {
                    throw PortableProfileError.invalid("Profile numeric exponents must be between -128 and 127.")
                }
                let significand = String(parts[0])
                let fractionDigits = significand.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
                let digits = significand.filter(\.isNumber)
                let trailingZeros = digits.reversed().prefix(while: { $0 == "0" }).count
                let coefficient = String(digits.drop(while: { $0 == "0" }).reversed().drop(while: { $0 == "0" }).reversed())
                let normalizedExponent = coefficient.isEmpty ? 0 : exponent - fractionDigits + trailingZeros
                let normalized = (text.hasPrefix("-") ? "-" : "") + (coefficient.isEmpty ? "0" : coefficient)
                    + "e\(normalizedExponent)"
                guard coefficient.count <= 38, (-128...127).contains(normalizedExponent),
                      let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), !number.isNaN else {
                    throw PortableProfileError.invalid("Profile numbers must fit 38 significant decimal digits and exponent -128 through 127.")
                }
                return .number(number)
            }
            return .string(text)
        case .alias: throw PortableProfileError.invalid("YAML aliases are not supported.")
        }
    }

    private static func node(_ value: ProfileValue) -> Node {
        switch value {
        case let .object(object):
            return Node(object.keys.sorted().map { (Node($0, Tag(.str), .doubleQuoted), node(object[$0]!)) })
        case let .array(array): return Node(array.map(node))
        case let .string(text): return Node(text, Tag(.str), .doubleQuoted)
        case let .number(number): return Node(NSDecimalNumber(decimal: number).stringValue, Tag(.implicit), .plain)
        case let .bool(bool): return Node(bool ? "true" : "false", Tag(.implicit), .plain)
        case .null: return Node("null", Tag(.implicit), .plain)
        }
    }
}
