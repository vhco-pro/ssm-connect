import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// A child process of the Windows and Linux helpers, waited for on its own.
///
/// On Linux, Foundation's Process watches every child through a socket the child inherits, and
/// when that socket closes it waits for the child with a blocking waitpid on the one thread that
/// serves all children. OpenSSH closes its inherited descriptors as it starts, so while web
/// forwards ran that thread sat in waitpid for ssh and no other child's exit was seen: the plugin
/// could die unnoticed, and a short command never returned. Here each child gets a thread of its
/// own that waits for that child's pid alone. Elsewhere this is Foundation's Process.
///
/// The child starts with standard input from /dev/null, standard error discarded, and standard
/// output discarded or captured. Like Foundation, it starts with default signal handling and no
/// blocked signals, so a signal the helper ignores is not ignored by the child.
package final class ChildProcess: @unchecked Sendable {
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]?
    private let captureOutput: Bool
    private let lock = NSLock()
    private let exited = DispatchSemaphore(value: 0)
    private var started = false
    private var pid: Int32 = 0
    private var status: Int32?
    private var exitHandler: (@Sendable (Int32) -> Void)?
    #if os(Linux)
    private let outputRead = DispatchSemaphore(value: 0)
    private var output = Data()
    #else
    private let process = Process()
    private var pipe: Pipe?
    #endif

    /// `environment` replaces the helper's environment when given.
    package init(executable: String, arguments: [String], environment: [String: String]? = nil,
                 captureOutput: Bool = false) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.captureOutput = captureOutput
    }

    /// Called once, on a background thread, with the exit code or the terminating signal's number.
    /// Set it before `run()`.
    package func onExit(_ handler: @escaping @Sendable (Int32) -> Void) {
        lock.withLock { exitHandler = handler }
    }

    package var isRunning: Bool { lock.withLock { started && status == nil } }
    package var processIdentifier: Int32 { lock.withLock { pid } }
    /// The exit code, or the terminating signal's number; nil while the child runs.
    package var terminationStatus: Int32? { lock.withLock { status } }

    /// Blocks until the child has exited.
    package func waitUntilExit() {
        exited.wait()
        exited.signal()
    }

    /// Asks the child to end (SIGTERM on Linux).
    package func terminate() {
        guard isRunning else { return }
        #if os(Linux)
        _ = kill(processIdentifier, SIGTERM)
        #else
        process.terminate()
        #endif
    }

    /// Standard output, once the child has exited and closed it. A descendant that keeps it open
    /// gets one second before what was read so far is returned.
    package func capturedOutput() -> Data {
        waitUntilExit()
        #if os(Linux)
        _ = outputRead.wait(timeout: .now() + 1)
        return lock.withLock { output }
        #else
        return pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        #endif
    }

    private func finish(_ code: Int32) {
        let handler: (@Sendable (Int32) -> Void)? = lock.withLock {
            status = code
            return exitHandler
        }
        exited.signal()
        handler?(code)
    }

    #if os(Linux)
    package func run() throws {
        var fds: [Int32] = [-1, -1]
        if captureOutput {
            // Glibc's pipe2 is not imported, so close-on-exec is set right after pipe. A child
            // spawned on another thread in between could inherit the write end; capturedOutput's
            // one-second limit covers that.
            guard pipe(&fds) == 0 else { throw POSIXError(errno) }
            fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        if captureOutput { posix_spawn_file_actions_adddup2(&actions, fds[1], 1) }
        else { posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0) }
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        var attributes = posix_spawnattr_t()
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t()
        sigemptyset(&mask)
        posix_spawnattr_setsigmask(&attributes, &mask)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?]? = environment.map { values in
            values.map { strdup("\($0.key)=\($0.value)") } + [nil]
        }
        defer { envp?.forEach { free($0) } }
        var child: pid_t = 0
        let result = envp.map { envp in
            posix_spawn(&child, executable, &actions, &attributes, argv, envp)
        } ?? posix_spawn(&child, executable, &actions, &attributes, argv, environ)
        if captureOutput { close(fds[1]) }
        guard result == 0 else {
            if captureOutput { close(fds[0]) }
            throw POSIXError(result)
        }
        lock.withLock {
            started = true
            pid = child
        }
        if captureOutput {
            let descriptor = fds[0]
            Thread.detachNewThread { [self] in
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = read(descriptor, &buffer, buffer.count)
                    if count > 0 { data.append(buffer, count: count) }
                    else if count < 0, errno == EINTR { continue }
                    else { break }
                }
                close(descriptor)
                lock.withLock { output = data }
                outputRead.signal()
            }
        }
        Thread.detachNewThread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) == -1, errno == EINTR {}
            // WIFEXITED / WEXITSTATUS / WTERMSIG, which Swift does not import.
            finish(raw & 0x7F == 0 ? (raw >> 8) & 0xFF : raw & 0x7F)
        }
    }
    #else
    package func run() throws {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        if captureOutput {
            let pipe = Pipe()
            self.pipe = pipe
            process.standardOutput = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
        }
        process.terminationHandler = { [self] process in finish(process.terminationStatus) }
        try process.run()
        lock.withLock {
            started = true
            pid = process.processIdentifier
        }
    }
    #endif
}

#if os(Linux)
private extension POSIXError {
    init(_ code: Int32) { self.init(POSIXErrorCode(rawValue: code) ?? .EIO) }
}
#endif
