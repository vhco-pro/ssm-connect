import CryptoKit
import Darwin
import Foundation

struct ProfileFileRevision: Codable, Equatable {
    let digest: String
    let inode: UInt64
    let device: Int32
    let permissions: UInt16
    let metadataVersion: String
}

struct ProfileFileSnapshot {
    let url: URL
    let document: PortableProfileDocument
    let revision: ProfileFileRevision
    let isWritable: Bool
}

struct ProfileAttachment: Codable, Equatable {
    var url: URL
    var revision: ProfileFileRevision
    var canonicalSaveAccepted = false
}

enum ProfileFileIO {
    static func read(_ url: URL) throws -> ProfileFileSnapshot {
        let url = canonicalURL(url)
        let raw = try readRaw(url)
        return ProfileFileSnapshot(url: url,
            document: try ProfileDocumentCodec.read(raw.data, format: ProfileFileFormat(url: url)),
            revision: raw.revision, isWritable: raw.isWritable)
    }

    static func save(_ document: PortableProfileDocument, to url: URL, expected: ProfileFileRevision?,
                     beforeCommit: () throws -> Void = {}) throws -> ProfileFileRevision {
        let url = canonicalURL(url)
        let data = try ProfileDocumentCodec.write(document, format: ProfileFileFormat(url: url))
        var coordinationError: NSError?
        var writeError: Error?
        var revision: ProfileFileRevision?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinated in
            do {
                if let expected {
                    let current = try readRaw(coordinated)
                    guard current.revision == expected else { throw PortableProfileError.conflict }
                    guard current.isWritable else {
                        throw PortableProfileError.invalid("This profile file is read-only. Save a local copy instead.")
                    }
                }
                let directory = coordinated.deletingLastPathComponent()
                let temporary = directory.appendingPathComponent(".ssm-profile-" + UUID().uuidString)
                let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                guard descriptor >= 0 else { throw posixError() }
                defer {
                    close(descriptor)
                    unlink(temporary.path)
                }
                if expected != nil {
                    let source = open(coordinated.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
                    guard source >= 0 else { throw posixError() }
                    defer { close(source) }
                    guard fcopyfile(source, descriptor, nil, copyfile_flags_t(COPYFILE_SECURITY)) == 0 else {
                        throw posixError()
                    }
                } else {
                    guard let emptyACL = acl_init(0) else { throw posixError() }
                    defer { acl_free(UnsafeMutableRawPointer(emptyACL)) }
                    guard acl_set_fd(descriptor, emptyACL) == 0 else { throw posixError() }
                }
                try data.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let count = Darwin.write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw posixError() }
                        offset += count
                    }
                }
                let mode = mode_t(expected?.permissions ?? 0o600)
                guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw posixError() }
                try beforeCommit()
                if let expected {
                    guard try readRaw(coordinated).revision == expected else { throw PortableProfileError.conflict }
                    guard rename(temporary.path, coordinated.path) == 0 else { throw posixError() }
                } else {
                    guard renamex_np(temporary.path, coordinated.path, UInt32(RENAME_EXCL)) == 0 else {
                        if errno == EEXIST { throw PortableProfileError.conflict }
                        throw posixError()
                    }
                }
                var written = stat()
                guard fstat(descriptor, &written) == 0 else { throw posixError() }
                revision = makeRevision(data, status: written)
            } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
        guard let revision else { throw PortableProfileError.invalid("The coordinated profile save did not complete.") }
        return revision
    }

    static func existingRevision(_ url: URL) throws -> ProfileFileRevision? {
        let url = canonicalURL(url)
        var status = stat()
        if lstat(url.path, &status) != 0 {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        return try readRaw(url).revision
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    private static func readRaw(_ url: URL) throws -> (data: Data, revision: ProfileFileRevision, isWritable: Bool) {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw PortableProfileError.invalid("Symbolic-link profile files are not supported. Choose the regular file.") }
            throw posixError()
        }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw posixError() }
        guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
            throw PortableProfileError.invalid("Profile files must be regular files without hard links.")
        }
        guard status.st_size <= ProfileDocumentCodec.maximumBytes else {
            throw PortableProfileError.invalid("Profile files must be at most 256 KiB.")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw posixError() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= ProfileDocumentCodec.maximumBytes else {
                throw PortableProfileError.invalid("Profile files must be at most 256 KiB.")
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0 else { throw posixError() }
        guard status.st_size == after.st_size, status.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              status.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw PortableProfileError.conflict }
        let permissions = UInt16(status.st_mode & 0o777)
        return (data, makeRevision(data, status: status),
            status.st_uid == getuid() && permissions & 0o200 != 0
                && FileManager.default.isWritableFile(atPath: url.path)
                && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path))
    }

    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeRevision(_ data: Data, status: stat) -> ProfileFileRevision {
        ProfileFileRevision(digest: digest(data), inode: UInt64(status.st_ino), device: status.st_dev,
            permissions: UInt16(status.st_mode & 0o777),
            metadataVersion: "\(status.st_ctimespec.tv_sec):\(status.st_ctimespec.tv_nsec)")
    }
}
