import Foundation

extension URL {
    /// The path to hand to another program, or to write into a file another program reads (ssh,
    /// DCV Viewer): "C:\..." on Windows, where Foundation's `path` is "/C:/...",
    /// and `path` unchanged on macOS and Linux.
    package var externalPath: String {
        #if os(Windows)
        withUnsafeFileSystemRepresentation { String(cString: $0!) }
        #else
        path
        #endif
    }
}
