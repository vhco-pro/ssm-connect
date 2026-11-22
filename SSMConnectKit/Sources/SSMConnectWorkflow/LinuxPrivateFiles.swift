#if os(Linux)
import Foundation
import Glibc

/// User-only files on Linux: folders mode 0700 owned by the user, files written to an exclusive
/// mode-0600 temporary, synced and renamed over the target, so a reader sees the old or the new
/// contents and nobody else can read either. A symbolic link, or a file or folder owned by someone
/// else, is refused instead of being written through.
package enum LinuxPrivateFiles {
    package enum Failure: Error, Equatable {
        /// The path is a symbolic link, not a regular file or folder, or owned by another user.
        case unsafe(String)
        /// A system call failed.
        case io(String, Int32)
    }

    /// Creates the folder mode 0700, creating missing parents the same way, or makes an existing
    /// folder of the user's mode 0700.
    package static func directory(_ url: URL) throws {
        let path = url.path
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else { throw Failure.io("lstat \(path)", errno) }
            let parent = url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard mkdir(path, 0o700) == 0 || errno == EEXIST else { throw Failure.io("mkdir \(path)", errno) }
            guard lstat(path, &metadata) == 0 else { throw Failure.io("lstat \(path)", errno) }
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafe("\(path) is not a folder") }
        guard metadata.st_uid == getuid() else { throw Failure.unsafe("\(path) belongs to another user") }
        if metadata.st_mode & 0o077 != 0, chmod(path, 0o700) != 0 { throw Failure.io("chmod \(path)", errno) }
    }

    /// Writes `data` to `url` user-only and atomically.
    package static func write(_ data: Data, to url: URL, createParent: Bool = true) throws {
        let folder = url.deletingLastPathComponent()
        if createParent { try directory(folder) }
        var metadata = stat()
        if lstat(url.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG else { throw Failure.unsafe("\(url.path) is not a regular file") }
            guard metadata.st_uid == getuid() else { throw Failure.unsafe("\(url.path) belongs to another user") }
        }
        let temporary = folder.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp").path
        let descriptor = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw Failure.io("open \(temporary)", errno) }
        var renamed = false
        defer { if !renamed { unlink(temporary) } }
        do {
            defer { close(descriptor) }
            try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
                var offset = 0
                while offset < buffer.count {
                    let written = Glibc.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw Failure.io("write \(temporary)", errno)
                    }
                    offset += written
                }
            }
            // The umask can only narrow the creation mode; set it exactly.
            guard fchmod(descriptor, 0o600) == 0 else { throw Failure.io("fchmod \(temporary)", errno) }
            guard fsync(descriptor) == 0 else { throw Failure.io("fsync \(temporary)", errno) }
        }
        guard rename(temporary, url.path) == 0 else { throw Failure.io("rename \(url.path)", errno) }
        renamed = true
    }

    /// Whether the path is the user's, with no access for anyone else.
    package static func isOwnerOnly(_ url: URL) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0 && metadata.st_uid == getuid() && metadata.st_mode & 0o077 == 0
    }
}
#endif
