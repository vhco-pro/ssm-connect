import Darwin
import Foundation
import SSMConnectWorkflow

extension OwnerOnlyFiles {
    /// POSIX ownership, permission bits and an `fcntl` write lock.
    package static let posix = OwnerOnlyFiles(
        isOwnerOnly: { attributes in
            attributes[.ownerAccountID] as? UInt32 == getuid()
                && ((attributes[.posixPermissions] as? Int ?? 0) & 0o077) == 0
        },
        withExclusiveLock: { url, body in
            let descriptor = Darwin.open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw RemoteSSHError.configurationConflict }
            defer { close(descriptor) }
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                  metadata.st_mode & 0o077 == 0 else { throw RemoteSSHError.configurationConflict }
            var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
            guard fcntl(descriptor, F_SETLK, &lock) == 0 else { throw RemoteSSHError.configurationConflict }
            defer {
                lock.l_type = Int16(F_UNLCK)
                _ = fcntl(descriptor, F_SETLK, &lock)
            }
            try body()
        }
    )
}
