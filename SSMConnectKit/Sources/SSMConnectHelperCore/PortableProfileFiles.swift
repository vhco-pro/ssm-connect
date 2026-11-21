import Crypto
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Attached profile files on Windows and Linux: read whole, identified by the SHA-256 of their
/// content with size and modification time, and saved only while the file still has the revision
/// the save expects, by writing a sibling and moving it into place.
package struct PortableProfileFiles: ProfileFileAccessing {
    let replace: @Sendable (Data, URL) throws -> Void

    /// `replace` writes a file atomically on the platform.
    package init(replace: @escaping @Sendable (Data, URL) throws -> Void) { self.replace = replace }

    package func read(_ url: URL) throws -> ProfileFileSnapshot {
        let data = try Data(contentsOf: url)
        return ProfileFileSnapshot(url: url, document: try ProfileDocumentCodec.read(data, format: ProfileFileFormat(url: url)),
                                   revision: try revision(url, data), isWritable: FileManager.default.isWritableFile(atPath: url.path))
    }

    package func save(_ document: PortableProfileDocument, to url: URL, expected: ProfileFileRevision?,
                      beforeCommit: () throws -> Void) throws -> ProfileFileRevision {
        guard try existingRevision(url) == expected else { throw CocoaError(.fileWriteUnknown) }
        let data = try ProfileDocumentCodec.write(document, format: ProfileFileFormat(url: url))
        try beforeCommit()
        try replace(data, url)
        return try revision(url, data)
    }

    package func existingRevision(_ url: URL) throws -> ProfileFileRevision? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try revision(url, Data(contentsOf: url))
    }

    private func revision(_ url: URL, _ data: Data) throws -> ProfileFileRevision {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return ProfileFileRevision(digest: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                   inode: UInt64(data.count), device: 0, permissions: 0o600,
                                   metadataVersion: "portable-1:\(modified)")
    }
}
