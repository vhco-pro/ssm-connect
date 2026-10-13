import CryptoKit
import CFNetwork
import Darwin
import Foundation

enum ProxyPreference: Equatable, Codable {
    case bool(Bool), integer(Int), string(String)

    var json: String {
        get throws {
            let object: Any
            switch self {
            case .bool(let value): object = value
            case .integer(let value): object = value
            case .string(let value): object = value
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: object,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
        }
    }
    static func render(_ values: [String: ProxyPreference]) throws -> String {
        try values.keys.sorted().map { "user_pref(\"\($0)\", \(try values[$0]!.json));" }.joined(separator: "\n") + "\n"
    }
    static func parse(_ contents: String) throws -> [String: ProxyPreference] {
        let pattern = #"(?m)^user_pref\("(network\.proxy\.[a-zA-Z0-9_\.]+|network\.dns\.disablePrefetch)", (.+)\);$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let string = contents as NSString
        var values: [String: ProxyPreference] = [:]
        for match in expression.matches(in: contents, range: NSRange(location: 0, length: string.length)) {
            let key = string.substring(with: match.range(at: 1))
            let data = Data(string.substring(with: match.range(at: 2)).utf8)
            let decoder = JSONDecoder()
            if let value = try? decoder.decode(Bool.self, from: data) { values[key] = .bool(value) }
            else if let value = try? decoder.decode(Int.self, from: data) { values[key] = .integer(value) }
            else if let value = try? decoder.decode(String.self, from: data) { values[key] = .string(value) }
            else { throw BrowserBootstrapError.conflict }
        }
        let relevantLines = contents.components(separatedBy: .newlines).filter {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                && ($0.contains("network.proxy.") || $0.contains("network.dns.disablePrefetch"))
        }
        guard relevantLines.count == expression.numberOfMatches(in: contents, range: NSRange(location: 0, length: string.length)) else {
            throw BrowserBootstrapError.conflict
        }
        return values
    }

    static func replacing(_ keys: Set<String>, with values: [String: ProxyPreference], in contents: String) throws -> String {
        _ = try parse(contents)
        let lines = contents.components(separatedBy: .newlines).filter { line in
            !keys.contains(where: { line.hasPrefix("user_pref(\"\($0)\",") })
        }
        return lines.joined(separator: "\n") + (contents.hasSuffix("\n") ? "" : "\n") + (try render(values))
    }
}

struct FirefoxProxySetup {
    enum WriteStage: CaseIterable { case transaction, user, preferences, journal, complete }
    struct Journal: Codable {
        let routing: BrowserRouting
        let previous: [String: ProxyPreference]
        let installed: [String: ProxyPreference]
        let originalUserDigest: String
        let userFileExisted: Bool
    }
    private struct Transaction: Codable {
        let before: Journal?
        let after: Journal?
    }
    let root: URL
    var beforeWrite: (WriteStage) throws -> Void = { _ in }
    private static let start = "// SSM Connect proxy settings begin\n"
    private static let end = "// SSM Connect proxy settings end\n"

    private func journalURL(_ routing: BrowserRouting) -> URL {
        let digest = SHA256.hash(data: Data(routing.profilePath.utf8)).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent("Existing", isDirectory: true).appendingPathComponent(digest + ".json")
    }
    private func profileFile(_ routing: BrowserRouting, _ name: String) -> URL {
        URL(fileURLWithPath: routing.profilePath, isDirectory: true).appendingPathComponent(name)
    }
    private func transactionURL(_ routing: BrowserRouting) -> URL {
        journalURL(routing).appendingPathExtension("pending")
    }
    private func read(_ url: URL) throws -> String {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw BrowserBootstrapError.conflict
        }
        return FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
    }
    private func digest(_ contents: String) -> String {
        SHA256.hash(data: Data(contents.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func block(_ values: [String: ProxyPreference]) throws -> String {
        Self.start + (try ProxyPreference.render(values)) + Self.end
    }
    private func journal(_ routing: BrowserRouting) throws -> Journal {
        try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL(routing)))
    }
    func isInstalled(_ routing: BrowserRouting) throws -> Bool {
        guard !FileManager.default.fileExists(atPath: transactionURL(routing).path) else {
            throw BrowserBootstrapError.interruptedSetup
        }
        guard FileManager.default.fileExists(atPath: journalURL(routing).path) else { return false }
        try verify(routing)
        return true
    }
    func inspect(_ routing: BrowserRouting) throws {
        try requireUnlocked(routing)
        try inspectUnlocked(routing)
    }
    private func inspectUnlocked(_ routing: BrowserRouting) throws {
        guard !FileManager.default.fileExists(atPath: transactionURL(routing).path) else {
            throw BrowserBootstrapError.interruptedSetup
        }
        let directory = URL(fileURLWithPath: routing.profilePath)
        guard routing.mode == .existing, routing.choice == .zen,
              directory.resolvingSymlinksInPath() == directory.standardizedFileURL else { throw BrowserBootstrapError.conflict }
        let user = try read(profileFile(routing, "user.js"))
        guard !user.contains(Self.start), try ProxyPreference.parse(user).isEmpty else { throw BrowserBootstrapError.conflict }
        let preferences = try ProxyPreference.parse(read(profileFile(routing, "prefs.js")))
        if let type = preferences["network.proxy.type"], type != .integer(0) && type != .integer(5) {
            throw BrowserBootstrapError.conflict
        }
        if let pac = preferences["network.proxy.autoconfig_url"], pac != .string("") { throw BrowserBootstrapError.conflict }
        if preferences["network.proxy.type"] != .integer(0),
           let system = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any],
           ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
            .contains(where: { (system[$0] as? NSNumber)?.boolValue == true }) {
            throw BrowserBootstrapError.conflict
        }
        try checkProxyExtensions(routing)
        if FileManager.default.fileExists(atPath: journalURL(routing).path) { throw BrowserBootstrapError.conflict }
    }
    private func checkProxyExtensions(_ routing: BrowserRouting) throws {
        if FileManager.default.fileExists(atPath: profileFile(routing, "extensions.json").path) {
            let object = try JSONSerialization.jsonObject(with: Data(contentsOf: profileFile(routing, "extensions.json"))) as? [String: Any]
            let addons = object?["addons"] as? [[String: Any]] ?? []
            if addons.contains(where: { addon in
                let permissions = addon["userPermissions"] as? [String: Any]
                return (permissions?["permissions"] as? [String] ?? []).contains("proxy")
            }) { throw BrowserBootstrapError.conflict }
        }
    }
    func verify(_ routing: BrowserRouting) throws {
        try checkProxyExtensions(routing)
        let record = try journal(routing)
        guard record.routing == routing else { throw BrowserBootstrapError.conflict }
        let user = try read(profileFile(routing, "user.js"))
        let expectedBlock = try block(record.installed)
        guard user.hasSuffix(expectedBlock),
              digest(String(user.dropLast(expectedBlock.count))) == record.originalUserDigest else { throw BrowserBootstrapError.conflict }
        let current = try ProxyPreference.parse(read(profileFile(routing, "prefs.js")))
        guard record.installed.allSatisfy({ entry in
            let effective = current[entry.key] ?? (entry.key == "network.proxy.socks5_remote_dns" ? .bool(true) : nil)
            return effective == entry.value
        }) else { throw BrowserBootstrapError.conflict }
    }
    func install(_ routing: BrowserRouting) throws {
        try withProfileLock(routing) { try installUnlocked(routing) }
    }
    private func installUnlocked(_ routing: BrowserRouting) throws {
        try recover(routing)
        if try isInstalled(routing) { return }
        try inspectUnlocked(routing)
        let userURL = profileFile(routing, "user.js")
        let prefsURL = profileFile(routing, "prefs.js")
        let user = try read(userURL)
        let preferences = try read(prefsURL)
        let installed = try routing.firefoxPreferences
        let keys = Set(installed.keys)
        let previous = try ProxyPreference.parse(preferences).filter { keys.contains($0.key) }
        let prefix = user.isEmpty || user.hasSuffix("\n") ? user : user + "\n"
        let record = Journal(routing: routing, previous: previous, installed: installed,
                             originalUserDigest: digest(prefix), userFileExisted: FileManager.default.fileExists(atPath: userURL.path))
        try beforeWrite(.transaction)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(Transaction(before: nil, after: record)), to: transactionURL(routing))
        try beforeWrite(.user)
        try BrowserPrivateFiles.write(Data((prefix + (try block(installed))).utf8), to: userURL, createParent: false)
        try beforeWrite(.preferences)
        try BrowserPrivateFiles.write(Data(try ProxyPreference.replacing(keys, with: installed, in: preferences).utf8), to: prefsURL, createParent: false)
        try beforeWrite(.journal)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(record), to: journalURL(routing))
        try verify(routing)
        try beforeWrite(.complete)
        try FileManager.default.removeItem(at: transactionURL(routing))
    }
    func inspectUpdate(_ routing: BrowserRouting) throws {
        try requireUnlocked(routing)
        guard !FileManager.default.fileExists(atPath: transactionURL(routing).path) else {
            throw BrowserBootstrapError.interruptedSetup
        }
        if FileManager.default.fileExists(atPath: journalURL(routing).path) {
            try verify(journal(routing).routing)
        } else { try inspect(routing) }
    }
    func update(_ routing: BrowserRouting) throws {
        try withProfileLock(routing) { try updateUnlocked(routing) }
    }
    private func updateUnlocked(_ routing: BrowserRouting) throws {
        try recover(routing)
        guard FileManager.default.fileExists(atPath: journalURL(routing).path) else { try installUnlocked(routing); return }
        let previousRecord = try journal(routing)
        try verify(previousRecord.routing)
        let installed = try routing.firefoxPreferences
        let userURL = profileFile(routing, "user.js")
        let prefsURL = profileFile(routing, "prefs.js")
        let user = try read(userURL)
        let prefs = try read(prefsURL)
        let prefix = String(user.dropLast(try block(previousRecord.installed).count))
        let record = Journal(routing: routing, previous: previousRecord.previous, installed: installed,
            originalUserDigest: previousRecord.originalUserDigest, userFileExisted: previousRecord.userFileExisted)
        try beforeWrite(.transaction)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(Transaction(before: previousRecord, after: record)), to: transactionURL(routing))
        try beforeWrite(.user)
        try BrowserPrivateFiles.write(Data((prefix + (try block(installed))).utf8), to: userURL, createParent: false)
        try beforeWrite(.preferences)
        try BrowserPrivateFiles.write(Data(try ProxyPreference.replacing(Set(installed.keys), with: installed, in: prefs).utf8),
                                      to: prefsURL, createParent: false)
        try beforeWrite(.journal)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(record), to: journalURL(routing))
        try verify(routing)
        try beforeWrite(.complete)
        try FileManager.default.removeItem(at: transactionURL(routing))
    }
    func restore(_ routing: BrowserRouting) throws {
        try withProfileLock(routing) { try restoreUnlocked(routing) }
    }
    private func restoreUnlocked(_ routing: BrowserRouting) throws {
        let recovered = try recover(routing)
        if recovered && !FileManager.default.fileExists(atPath: journalURL(routing).path) { return }
        let record = try journal(routing)
        guard record.routing.workstationID == routing.workstationID, record.routing.choice == routing.choice,
              record.routing.mode == routing.mode, record.routing.profilePath == routing.profilePath else {
            throw BrowserBootstrapError.conflict
        }
        try verify(record.routing)
        let userURL = profileFile(routing, "user.js")
        let prefsURL = profileFile(routing, "prefs.js")
        let user = try read(userURL)
        let restored = try ProxyPreference.replacing(Set(record.installed.keys), with: record.previous, in: read(prefsURL))
        try beforeWrite(.transaction)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(Transaction(before: record, after: nil)), to: transactionURL(routing))
        try beforeWrite(.preferences)
        try BrowserPrivateFiles.write(Data(restored.utf8), to: prefsURL, createParent: false)
        let original = String(user.dropLast(try block(record.installed).count))
        try beforeWrite(.user)
        if record.userFileExisted { try BrowserPrivateFiles.write(Data(original.utf8), to: userURL, createParent: false) }
        else { try FileManager.default.removeItem(at: userURL) }
        try beforeWrite(.journal)
        try FileManager.default.removeItem(at: journalURL(routing))
        try beforeWrite(.complete)
        try FileManager.default.removeItem(at: transactionURL(routing))
    }

    @discardableResult private func recover(_ routing: BrowserRouting) throws -> Bool {
        let pending = transactionURL(routing)
        guard FileManager.default.fileExists(atPath: pending.path) else { return false }
        let transaction = try JSONDecoder().decode(Transaction.self, from: Data(contentsOf: pending))
        guard let scope = transaction.before ?? transaction.after,
              scope.routing.workstationID == routing.workstationID,
              scope.routing.choice == routing.choice, scope.routing.mode == routing.mode,
              scope.routing.profilePath == routing.profilePath else { throw BrowserBootstrapError.conflict }
        try checkProxyExtensions(routing)
        let userURL = profileFile(routing, "user.js")
        let prefsURL = profileFile(routing, "prefs.js")
        let user = try read(userURL)
        let preferences = try read(prefsURL)
        let current = try ProxyPreference.parse(preferences)
        let before = transaction.before?.installed ?? scope.previous
        let after = transaction.after?.installed ?? scope.previous
        let keys = Set(scope.installed.keys)
        func matches(_ expected: [String: ProxyPreference]) -> Bool {
            keys.allSatisfy { key in
                let defaultValue: ProxyPreference? = key == "network.proxy.socks5_remote_dns" ? .bool(true) : nil
                return (current[key] ?? defaultValue) == (expected[key] ?? defaultValue)
            }
        }
        guard matches(before) || matches(after) else { throw BrowserBootstrapError.conflict }
        var prefix = user
        for record in [transaction.before, transaction.after].compactMap({ $0 }) {
            let suffix = try block(record.installed)
            if user.hasSuffix(suffix) { prefix = String(user.dropLast(suffix.count)); break }
        }
        if !prefix.isEmpty && !prefix.hasSuffix("\n") { prefix += "\n" }
        guard digest(prefix) == scope.originalUserDigest else { throw BrowserBootstrapError.conflict }
        if FileManager.default.fileExists(atPath: journalURL(routing).path) {
            let stored = try journal(routing)
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            let data = try encoder.encode(stored)
            guard try [transaction.before, transaction.after].compactMap({ $0 }).contains(where: {
                try encoder.encode($0) == data
            }) else { throw BrowserBootstrapError.conflict }
        }
        try BrowserPrivateFiles.write(Data(try ProxyPreference.replacing(keys, with: before, in: preferences).utf8),
                                      to: prefsURL, createParent: false)
        if let previous = transaction.before {
            try BrowserPrivateFiles.write(Data((prefix + (try block(previous.installed))).utf8), to: userURL, createParent: false)
            try BrowserPrivateFiles.write(try JSONEncoder().encode(previous), to: journalURL(routing))
        } else {
            if scope.userFileExisted { try BrowserPrivateFiles.write(Data(prefix.utf8), to: userURL, createParent: false) }
            else if FileManager.default.fileExists(atPath: userURL.path) { try FileManager.default.removeItem(at: userURL) }
            if FileManager.default.fileExists(atPath: journalURL(routing).path) { try FileManager.default.removeItem(at: journalURL(routing)) }
        }
        try FileManager.default.removeItem(at: pending)
        return true
    }

    private func requireUnlocked(_ routing: BrowserRouting) throws {
        let descriptor = open(profileFile(routing, ".parentlock").path, O_RDONLY)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_GETLK, &lock) == 0, lock.l_type == Int16(F_UNLCK) else {
            throw BrowserBootstrapError.closeBrowser
        }
    }

    private func withProfileLock(_ routing: BrowserRouting, perform: () throws -> Void) throws {
        let descriptor = open(profileFile(routing, ".parentlock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw BrowserBootstrapError.closeBrowser }
        defer { close(descriptor) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_SETLK, &lock) == 0 else { throw BrowserBootstrapError.closeBrowser }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = fcntl(descriptor, F_SETLK, &lock)
        }
        try perform()
    }
}