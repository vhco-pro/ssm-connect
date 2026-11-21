import Darwin
import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

package enum RemoteEditorPreflight {
    package static func check(_ executable: String) async throws {
        let data = try await run(executable, arguments: ["--locate-extension", "ms-vscode-remote.remote-ssh"])
        let directory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty,
              FileManager.default.fileExists(atPath: directory + "/package.json") else { throw RemoteSSHError.unavailable }
    }

    package static func run(_ executable: String, arguments: [String], timeout: Duration = .seconds(15)) async throws -> Data {
        try Task.checkCancellation()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-editor-cli-" + UUID().uuidString)
        try BrowserPrivateFiles.write(Data(), to: outputURL, createParent: false)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning {
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                guard ContinuousClock.now < deadline,
                      (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1024 else { throw RemoteSSHError.unavailable }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 64 * 1024 + 1) ?? Data()
            guard process.terminationStatus == 0, data.count <= 64 * 1024 else { throw RemoteSSHError.unavailable }
            return data
        } catch {
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
    }
}