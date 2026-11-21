import Foundation
import SSMConnectDomain

package struct ProfileFileRevision: Codable, Equatable {
    package let digest: String
    package let inode: UInt64
    package let device: Int32
    package let permissions: UInt16
    package let metadataVersion: String

    package init(digest: String, inode: UInt64, device: Int32, permissions: UInt16, metadataVersion: String) {
        self.digest = digest
        self.inode = inode
        self.device = device
        self.permissions = permissions
        self.metadataVersion = metadataVersion
    }
}

package struct ProfileFileSnapshot {
    package let url: URL
    package let document: PortableProfileDocument
    package let revision: ProfileFileRevision
    package let isWritable: Bool

    package init(url: URL, document: PortableProfileDocument, revision: ProfileFileRevision, isWritable: Bool) {
        self.url = url
        self.document = document
        self.revision = revision
        self.isWritable = isWritable
    }
}

package struct ProfileAttachment: Codable, Equatable {
    package var url: URL
    package var revision: ProfileFileRevision
    package var canonicalSaveAccepted = false

    package init(url: URL, revision: ProfileFileRevision, canonicalSaveAccepted: Bool = false) {
        self.url = url
        self.revision = revision
        self.canonicalSaveAccepted = canonicalSaveAccepted
    }
}

/// Reading and saving attached profile files, from the platform: the revision identifies the
/// exact file content and identity a save expects, so a file changed underneath is never
/// overwritten.
package protocol ProfileFileAccessing: Sendable {
    func read(_ url: URL) throws -> ProfileFileSnapshot
    func save(_ document: PortableProfileDocument, to url: URL, expected: ProfileFileRevision?,
              beforeCommit: () throws -> Void) throws -> ProfileFileRevision
    func existingRevision(_ url: URL) throws -> ProfileFileRevision?
}

extension ProfileFileAccessing {
    package func save(_ document: PortableProfileDocument, to url: URL, expected: ProfileFileRevision?) throws -> ProfileFileRevision {
        try save(document, to: url, expected: expected, beforeCommit: {})
    }
}
