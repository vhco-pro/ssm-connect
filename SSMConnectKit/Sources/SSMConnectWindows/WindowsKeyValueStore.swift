#if os(Windows)
import Foundation
import SSMConnectWorkflow

/// The key-value store behind profiles, settings and editor recovery on Windows: one JSON
/// document in the user's local application data, rewritten atomically with an owner-only DACL
/// on every change. Values are data or strings, as `KeyValueStoring` uses them.
package final class WindowsKeyValueStore: KeyValueStoring {
    private enum Value: Codable { case data(Data), string(String) }
    private let url: URL
    private var values: [String: Value]

    /// `%LOCALAPPDATA%\SSM Connect\settings.json`.
    package static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SSM Connect", isDirectory: true).appendingPathComponent("settings.json")
    }

    package init(url: URL = WindowsKeyValueStore.defaultURL) {
        self.url = url
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
        try? WindowsPrivateFiles.write(document, to: url)
    }
}
#endif
