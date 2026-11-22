import Foundation

/// The key-value store behind profiles, settings and editor recovery on Windows and Linux: one
/// JSON document, rewritten in full through the platform's private-file writer on every change.
/// Values are data or strings, as `KeyValueStoring` uses them.
package final class FileKeyValueStore: KeyValueStoring {
    private enum Value: Codable { case data(Data), string(String) }
    package let url: URL
    private let write: (Data, URL) throws -> Void
    private var values: [String: Value]

    package init(url: URL, write: @escaping (Data, URL) throws -> Void) {
        self.url = url
        self.write = write
        let data = try? Data(contentsOf: url)
        values = data.flatMap { try? JSONDecoder().decode([String: Value].self, from: $0) } ?? [:]
    }

    package func data(forKey key: String) -> Data? {
        if case let .data(value) = values[key] { return value }
        return nil
    }

    package func string(forKey key: String) -> String? {
        if case let .string(value) = values[key] { return value }
        return nil
    }

    package func set(_ value: Any?, forKey key: String) {
        switch value {
        case let data as Data: values[key] = .data(data)
        case let string as String: values[key] = .string(string)
        default: values[key] = nil
        }
        guard let document = try? JSONEncoder().encode(values) else { return }
        try? write(document, url)
    }
}

/// Versions of installed browsers that every platform reads the same way.
package enum BrowserVersions {
    /// Zen records its version as `Version=` in application.ini beside its executable.
    package static func zen(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("application.ini"), encoding: .utf8) else { return nil }
        return text.split(whereSeparator: \.isNewline).lazy
            .first { $0.hasPrefix("Version=") }
            .map { String($0.dropFirst("Version=".count)).trimmingCharacters(in: .whitespaces) }
    }
}
