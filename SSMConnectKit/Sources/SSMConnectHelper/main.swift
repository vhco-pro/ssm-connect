import Foundation
import SSMConnectHelperCore
import SSMConnectHelperProtocol

// The private helper a Windows or Linux shell starts as its child, connected by anonymous
// stdin/stdout pipes. Frames go to stdout only; diagnostics go to stderr. The helper exits when
// stdin closes, after cancelling what is running and running the workflows' quit work.

/// Writes to stdout and stderr through FileHandle, never stdio, so a closed pipe cannot trap and
/// exit() never waits on a stdio lock held by the reading thread.
final class Pipes: @unchecked Sendable {
    private let lock = NSLock()
    func send(_ frame: Frame) {
        guard let data = try? FrameCodec.encode(frame) else { return }
        lock.withLock { try? FileHandle.standardOutput.write(contentsOf: data) }
    }
    func diagnose(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("helper: \(message)\n".utf8))
    }
}

if CommandLine.arguments.dropFirst().first == "--build" {
    try? FileHandle.standardOutput.write(contentsOf: Data((HelperBuild.current + "\n").utf8))
    exit(0)
}

let pipes = Pipes()
let requests = ShellRequests()
#if os(Windows) || os(Linux)
let runtime = HelperRuntime(services: HelperComposition.production(requests: requests))
let commands = runtime.commands()
#else
// The helper ships on Windows and Linux only; elsewhere it serves the protocol with no commands.
let commands: [String: CommandSpec] = [:]
#endif
let session = HelperSession(build: HelperBuild.current, commands: commands, send: { pipes.send($0) })
requests.attach(session.events)

// Signing out on Linux ends the helper without closing its stdin: systemd stops the helper's unit
// with SIGTERM and kills it moments later. The helper first ends its session and runs the workflows'
// quit work, so no key, lease or connection file outlives it. On Windows the shell asks the helper
// to end when the session ends: the helper loads user32, so Windows sends it no console sign-out event.
#if !os(Windows)
signal(SIGTERM, SIG_IGN)
let sessionEnd = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sessionEnd.setEventHandler {
    Task { @MainActor in
        await HelperExit.end(session)
        exit(0)
    }
}
sessionEnd.resume()
#endif

let chunks = AsyncStream<Data> { continuation in
    Thread.detachNewThread {
        while true {
            let data = FileHandle.standardInput.availableData
            if data.isEmpty { break }
            continuation.yield(data)
        }
        continuation.finish()
    }
}

var reader = FrameReader()
readLoop: for await chunk in chunks {
    let lines: [Data]
    do { lines = try reader.append(chunk) } catch {
        pipes.diagnose("frame longer than \(FrameReader.maximumLength) bytes; stopping")
        await HelperExit.end(session)
        exit(2)
    }
    for line in lines where !line.isEmpty {
        do {
            await session.receive(try FrameCodec.decode(line))
        } catch {
            pipes.diagnose("malformed frame ignored")
        }
        if await session.isEnded { break readLoop }
    }
}
let refused = await session.wasRefused
await HelperExit.end(session)
exit(refused ? 1 : 0)
