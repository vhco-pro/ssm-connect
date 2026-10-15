import Foundation

struct RemoteSSHSetup {
    let root: URL
    let configURL: URL

    private var include: String {
        "Include \"" + root.appendingPathComponent("hosts").path.replacingOccurrences(of: "\"", with: "\\\"") + "/config\"\n"
    }
    private var journalURL: URL { root.appendingPathComponent("ssh-setup.json") }

    var isInstalled: Bool {
        guard FileManager.default.fileExists(atPath: journalURL.path),
              let data = try? Data(contentsOf: journalURL),
              let recorded = try? JSONDecoder().decode(String.self, from: data), recorded == include,
              let current = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
        return current.hasPrefix(include)
    }

    func install(consent: Bool) throws {
        guard consent else { return }
        if isInstalled { return }
        guard !FileManager.default.fileExists(atPath: journalURL.path),
              (try? configURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw RemoteSSHError.configurationConflict
        }
        let existing = FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8) : ""
        guard !existing.contains("ssm-connect-") else { throw RemoteSSHError.configurationConflict }
        try BrowserPrivateFiles.directory(configURL.deletingLastPathComponent())
        try BrowserPrivateFiles.directory(root.appendingPathComponent("hosts"))
        try BrowserPrivateFiles.write(Data("".utf8), to: root.appendingPathComponent("hosts/config"))
        try BrowserPrivateFiles.write(Data((include + existing).utf8), to: configURL, createParent: false)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(include), to: journalURL)
    }

    func writeHost(_ contents: String, profileID: UUID) throws {
        guard isInstalled else { throw RemoteSSHError.configurationConflict }
        let directory = root.appendingPathComponent("hosts")
        let file = directory.appendingPathComponent(profileID.uuidString.lowercased() + ".conf")
        try BrowserPrivateFiles.write(Data(contents.utf8), to: file)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "conf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let configuration = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined(separator: "\n")
        try BrowserPrivateFiles.write(Data(configuration.utf8), to: directory.appendingPathComponent("config"))
    }

    func restore() throws {
        guard isInstalled else { throw RemoteSSHError.configurationConflict }
        let contents = try String(contentsOf: configURL, encoding: .utf8)
        try BrowserPrivateFiles.write(Data(contents.dropFirst(include.count).utf8), to: configURL, createParent: false)
        try FileManager.default.removeItem(at: journalURL)
    }
}