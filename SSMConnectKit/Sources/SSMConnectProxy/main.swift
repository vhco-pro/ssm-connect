import Foundation
#if os(macOS)
import Darwin
import SSMConnectKit
#else
import SSMConnectAWS
import SSMConnectWorkflow
#endif

// The editor's SSH proxy: VS Code's SSH runs it as ProxyCommand with an owned lease. It refuses
// before any AWS call when the lease is invalid, from another build, expired or its owner is
// gone, and otherwise carries the SSH channel through the Session Manager plugin.

#if os(macOS)
func runProxy(_ path: String) async throws -> Int32 { try await RemoteSSHProxyRuntime.run(configurationPath: path) }
func failureMessage(_ error: Error) -> String { RemoteSSHProxyRuntime.failureMessage(for: error) }
let usage = RemoteSSHProxyRuntime.failureMessage
#else
#if os(Windows)
let ownerOnlyFiles = OwnerOnlyFiles.windows
#else
let ownerOnlyFiles = OwnerOnlyFiles.posix
#endif
/// The proxy never signs in interactively: it only reuses or silently refreshes the owner's SSO
/// session, so a sign-in request would come back as a rejected authorization.
let proxy = EditorProxy(owner: ProcessLeaseOwner(), files: ownerOnlyFiles,
                        auth: ClientAuthProvider(openURL: { _ in }), ec2: ClientEC2Service(), ssm: ClientSSMService(),
                        instanceConnect: ClientInstanceConnectService(),
                        isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) },
                        forceTerminate: { $0.terminate() })
func runProxy(_ path: String) async throws -> Int32 { try await proxy.run(configurationPath: path) }
func failureMessage(_ error: Error) -> String {
    EditorProxy.failureMessage(for: error, isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) })
}
let usage = EditorProxy.failureMessage
#endif

guard CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--configuration" else {
    try? FileHandle.standardError.write(contentsOf: Data(usage.utf8))
    exit(1)
}
do {
    exit(try await runProxy(CommandLine.arguments[2]))
} catch {
    try? FileHandle.standardError.write(contentsOf: Data(failureMessage(error).utf8))
    exit(1)
}
