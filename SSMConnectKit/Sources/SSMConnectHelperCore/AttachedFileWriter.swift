import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#endif

/// Saves an attached profile file on Windows and Linux as macOS does: a temporary file beside it
/// takes the data and replaces the file in one step. Only that file changes. The folder the user
/// keeps it in (Documents, a team share) keeps its own access rules, and the file keeps its own:
/// its security on Windows, its mode on Linux. A new file gets the folder's inherited rules on
/// Windows and mode 0600 on Linux, as on macOS. Profile files hold no credentials.
package enum AttachedFileWriter {
    package enum Failure: Error { case write(Int32) }

    package static func replace(_ data: Data, _ url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ssm-profile-" + UUID().uuidString)
        #if os(Windows)
        guard FileManager.default.createFile(atPath: temporary.path, contents: data) else { throw Failure.write(0) }
        let target = url.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let source = temporary.withUnsafeFileSystemRepresentation { String(cString: $0!) }
        let replaced = target.withCString(encodedAs: UTF16.self) { targetPath in
            source.withCString(encodedAs: UTF16.self) { sourcePath in
                FileManager.default.fileExists(atPath: url.path)
                    // ReplaceFileW keeps the replaced file's security descriptor and attributes.
                    ? ReplaceFileW(targetPath, sourcePath, nil, DWORD(REPLACEFILE_IGNORE_MERGE_ERRORS), nil, nil)
                    : MoveFileExW(sourcePath, targetPath, DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard replaced else {
            let error = GetLastError()
            try? FileManager.default.removeItem(at: temporary)
            throw Failure.write(Int32(bitPattern: error))
        }
        #else
        var current = stat()
        let mode = lstat(url.path, &current) == 0 ? current.st_mode & 0o7777 : 0o600
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw Failure.write(errno) }
        var committed = false
        defer {
            close(descriptor)
            if !committed { unlink(temporary.path) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.write(errno) }
                offset += count
            }
        }
        guard fchmod(descriptor, mode) == 0, fsync(descriptor) == 0 else { throw Failure.write(errno) }
        guard rename(temporary.path, url.path) == 0 else { throw Failure.write(errno) }
        committed = true
        #endif
    }
}
