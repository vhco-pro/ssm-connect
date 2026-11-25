import Crypto
import Foundation
import SSMConnectWorkflow

/// The temporary SSH key for web forwards and the editor on Windows and Linux: an Ed25519 key
/// generated in process and written user-only in OpenSSH's own file formats, which ssh reads as it
/// reads a key ssh-keygen made. No ssh-keygen command line is involved: on Windows, Foundation's
/// Process drops an empty argument, so `ssh-keygen -N ""` cannot be run there.
package struct NativeSSHKeyGenerator: SSHKeyGenerating {
    package init() {}

    package func generate() async throws -> SSHKeyMaterial {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ssm-connect-ssh-\(UUID().uuidString)", isDirectory: true)
        do {
            try BrowserPrivateFiles.directory(directory)
            let key = Curve25519.Signing.PrivateKey()
            let publicKey = Self.publicKeyLine(key.publicKey, comment: "ssm-connect")
            try BrowserPrivateFiles.write(Data(Self.privateKeyFile(key, comment: "ssm-connect").utf8),
                                          to: directory.appendingPathComponent("key"), createParent: false)
            try BrowserPrivateFiles.write(Data((publicKey + "\n").utf8), to: directory.appendingPathComponent("key.pub"),
                                          createParent: false)
            return SSHKeyMaterial(directory: directory, publicKey: publicKey)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw WebForwardsError.keyGenerationFailed
        }
    }

    /// The public key as an authorized_keys line: "ssh-ed25519 <base64 blob> <comment>".
    package static func publicKeyLine(_ key: Curve25519.Signing.PublicKey, comment: String) -> String {
        "ssh-ed25519 \(publicBlob(key).base64EncodedString()) \(comment)"
    }

    /// The private key in OpenSSH's "openssh-key-v1" format, unencrypted.
    package static func privateKeyFile(_ key: Curve25519.Signing.PrivateKey, comment: String,
                                       check: UInt32 = UInt32.random(in: .min ... .max)) -> String {
        let publicBytes = key.publicKey.rawRepresentation
        var secret = Data()
        secret.append(uint32(check))
        secret.append(uint32(check))
        secret.append(string(Data("ssh-ed25519".utf8)))
        secret.append(string(publicBytes))
        secret.append(string(key.rawRepresentation + publicBytes)) // seed, then public key
        secret.append(string(Data(comment.utf8)))
        var pad: UInt8 = 1
        while secret.count % 8 != 0 { secret.append(pad); pad += 1 }
        var body = Data("openssh-key-v1".utf8) + Data([0])
        body.append(string(Data("none".utf8))) // cipher
        body.append(string(Data("none".utf8))) // KDF
        body.append(string(Data()))            // KDF options
        body.append(uint32(1))                 // one key
        body.append(string(publicBlob(key.publicKey)))
        body.append(string(secret))
        let encoded = body.base64EncodedString()
        let lines = stride(from: 0, to: encoded.count, by: 70).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            return String(encoded[start..<(encoded.index(start, offsetBy: 70, limitedBy: encoded.endIndex) ?? encoded.endIndex)])
        }
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n") + "\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    static func publicBlob(_ key: Curve25519.Signing.PublicKey) -> Data {
        string(Data("ssh-ed25519".utf8)) + string(key.rawRepresentation)
    }

    static func uint32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    static func string(_ value: Data) -> Data { uint32(UInt32(value.count)) + value }
}
