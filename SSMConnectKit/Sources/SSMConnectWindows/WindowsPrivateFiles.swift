#if os(Windows)
import Foundation
import SSMConnectWorkflow
import WinSDK

/// Per-user private files on Windows: directories and files carry a protected DACL granting only
/// the current user, files are written to a temporary sibling created with that DACL and moved
/// over the target atomically, and a reparse point (symbolic link or junction) is never written
/// through.
package enum WindowsPrivateFiles {
    package enum Failure: Error, Equatable { case reparsePoint, create(DWORD), write(DWORD), replace(DWORD), lock }

    package static func directory(_ url: URL) throws {
        guard !isReparsePoint(url.nativePath) else { throw Failure.reparsePoint }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard !isReparsePoint(url.nativePath) else { throw Failure.reparsePoint }
        try WindowsSecurity.restrictToOwner(url.nativePath, container: true)
    }

    package static func write(_ data: Data, to url: URL, createParent: Bool = true) throws {
        if createParent { try directory(url.deletingLastPathComponent()) }
        guard !isReparsePoint(url.nativePath) else { throw Failure.reparsePoint }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { _ = temporary.nativePath.withCString(encodedAs: UTF16.self) { DeleteFileW($0) } }
        try WindowsSecurity.withOwnerOnlyDescriptor(container: false) { attributes in
            let handle = temporary.nativePath.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_WRITE), 0, attributes, DWORD(CREATE_NEW), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure.create(GetLastError()) }
            defer { CloseHandle(handle) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    var written: DWORD = 0
                    let chunk = DWORD(min(bytes.count - offset, 1 << 30))
                    guard WriteFile(handle, bytes.baseAddress!.advanced(by: offset), chunk, &written, nil) else {
                        throw Failure.write(GetLastError())
                    }
                    offset += Int(written)
                }
            }
            guard FlushFileBuffers(handle) else { throw Failure.write(GetLastError()) }
        }
        let moved = temporary.nativePath.withCString(encodedAs: UTF16.self) { source in
            url.nativePath.withCString(encodedAs: UTF16.self) { target in
                MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING) | DWORD(MOVEFILE_WRITE_THROUGH))
            }
        }
        guard moved else { throw Failure.replace(GetLastError()) }
    }

    /// Whether the file is owned by the current user with no access for anyone else.
    package static func isOwnerOnly(_ url: URL) -> Bool {
        !isReparsePoint(url.nativePath) && WindowsSecurity.isOwnerOnly(url.nativePath)
    }

    /// Runs `body` holding an unshared handle on an owner-only lock file, created if missing.
    package static func withExclusiveLock(_ url: URL, _ body: () throws -> Void) throws {
        try WindowsSecurity.withOwnerOnlyDescriptor(container: false) { attributes in
            let handle = url.nativePath.withCString(encodedAs: UTF16.self) {
                CreateFileW($0, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, attributes, DWORD(OPEN_ALWAYS),
                            DWORD(FILE_ATTRIBUTE_NORMAL) | DWORD(FILE_FLAG_OPEN_REPARSE_POINT), nil)
            }
            guard let handle, handle != INVALID_HANDLE_VALUE else { throw Failure.lock }
            defer { CloseHandle(handle) }
            guard !isReparsePoint(url.nativePath), WindowsSecurity.isOwnerOnly(url.nativePath) else { throw Failure.lock }
            try body()
        }
    }

    static func isReparsePoint(_ path: String) -> Bool {
        let attributes = path.withCString(encodedAs: UTF16.self) { GetFileAttributesW($0) }
        return attributes != INVALID_FILE_ATTRIBUTES && attributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) != 0
    }
}

extension URL {
    /// The path in the form Win32 expects ("C:\\..."), not Foundation's "/C:/..." form.
    var nativePath: String { withUnsafeFileSystemRepresentation { String(cString: $0!) } }
}

extension OwnerOnlyFiles {
    /// Windows: a protected DACL for the current user only, and an unshared lock handle.
    package static let windows = OwnerOnlyFiles(
        isOwnerOnly: { url, _ in WindowsPrivateFiles.isOwnerOnly(url) },
        withExclusiveLock: { url, body in
            do { try WindowsPrivateFiles.withExclusiveLock(url, body) }
            catch is WindowsPrivateFiles.Failure { throw RemoteSSHError.configurationConflict }
        }
    )
}
#endif
