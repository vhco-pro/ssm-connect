import Foundation
import Testing
@testable import SSMConnectHelperCore
@testable import SSMConnectWorkflow

/// The temporary SSH key for web forwards and the editor is generated in process in OpenSSH's own
/// formats, owner-only, and its path is one other programs (ssh) accept: "C:\..." on Windows, not
/// Foundation's "/C:/..." form (T28).
@Suite("SSH key generator")
struct KeyGeneratorTests {
    static var keygen: String? {
        #if os(Windows)
        let candidate = (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\OpenSSH\\ssh-keygen.exe"
        #else
        let candidate = "/usr/bin/ssh-keygen"
        #endif
        return FileManager.default.fileExists(atPath: candidate) ? candidate : nil
    }

    @Test("A key is generated in OpenSSH's formats, owner-only, at a path other programs accept")
    func generates() async throws {
        let key = try await NativeSSHKeyGenerator().generate()
        defer { key.remove() }
        #expect(key.publicKey.hasPrefix("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI"))
        #expect(key.publicKey.hasSuffix(" ssm-connect"))
        let file = try String(contentsOfFile: key.privateKeyPath, encoding: .utf8)
        #expect(file.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----\n") && file.hasSuffix("-----END OPENSSH PRIVATE KEY-----\n"))
        #expect(try String(contentsOfFile: key.privateKeyPath + ".pub", encoding: .utf8) == key.publicKey + "\n")
        #if os(Windows)
        #expect(!key.privateKeyPath.hasPrefix("/") && key.privateKeyPath.contains("\\"))
        #else
        #expect((try FileManager.default.attributesOfItem(atPath: key.privateKeyPath)[.posixPermissions] as? Int) == 0o600)
        #endif
    }

    @Test("ssh-keygen reads the private key back to the same public key",
          .enabled(if: KeyGeneratorTests.keygen != nil))
    func readableByOpenSSH() async throws {
        let key = try await NativeSSHKeyGenerator().generate()
        defer { key.remove() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try #require(KeyGeneratorTests.keygen))
        process.arguments = ["-y", "-f", key.privateKeyPath]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let derived = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(message)")
        let fields = { (line: String) in line.split(separator: " ").prefix(2).joined(separator: " ") }
        #expect(fields(derived.trimmingCharacters(in: .whitespacesAndNewlines)) == fields(key.publicKey))
    }

    @Test("Paths handed to other programs are native on every platform")
    func externalPath() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-key/key")
        #if os(Windows)
        #expect(!url.externalPath.hasPrefix("/") && url.externalPath.contains("\\"))
        #else
        #expect(url.externalPath == url.path)
        #endif
    }
}
