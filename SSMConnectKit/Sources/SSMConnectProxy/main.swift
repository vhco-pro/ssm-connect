import Darwin
import Foundation
import SSMConnectKit

@main struct SSMConnectProxy {
    static func main() async {
        guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--configuration" else {
            FileHandle.standardError.write(Data(RemoteSSHProxyRuntime.failureMessage.utf8))
            exit(1)
        }
        do {
            let result = try await RemoteSSHProxyRuntime.run(configurationPath: CommandLine.arguments[2])
            exit(result)
        } catch {
            FileHandle.standardError.write(Data(RemoteSSHProxyRuntime.failureMessage.utf8))
            exit(1)
        }
    }
}