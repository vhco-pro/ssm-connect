import Foundation
import SSMConnectAWS
import SSMConnectAWSClient
import SSMConnectDomain
import SSMConnectWorkflow
#if os(Windows)
import SSMConnectWindows
import WinSDK
#endif

/// The helper's production services. Windows composes the client services, the client SSO
/// provider and the Windows adapters here; Linux adds its adapters with T22. Elsewhere the helper
/// is not shipped and has no production composition.
package enum HelperComposition {
    #if os(Windows)
    @MainActor package static func production(requests: ShellRequests) -> HelperServices {
        let tools = WindowsTools()
        let environment = ProcessInfo.processInfo.environment
        let local = URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? NSTemporaryDirectory())
            .appendingPathComponent("SSM Connect", isDirectory: true)
        let home = URL(fileURLWithPath: environment["USERPROFILE"] ?? NSHomeDirectory())
        let platform = WorkflowPlatform(
            terminateChildProcess: { pid in
                guard let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
                TerminateProcess(process, 1)
                CloseHandle(process)
            },
            describeError: { AWSErrorText.message(for: $0) },
            isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) },
            isPermissionDenied: { ClientAuthProvider.isPermissionDenied($0) },
            isExpiredCredentials: { error in
                ClientAuthProvider.isRejectedAuthorization(error)
                    || ["ExpiredToken", "ExpiredTokenException", "UnauthorizedAccess"].contains((error as? AWSServiceError)?.typeName ?? "")
            },
            resolveUsername: { credentials, region in
                try await STSIdentityResolver(presigner: STSPresigner(region: region)).resolve(credentials: credentials).username
            },
            identityToken: { credentials, region in
                try STSPresigner(region: region).presignedGetCallerIdentityURL(credentials: credentials, now: Date())
            },
            ownerOnlyFiles: .windows)
        let dcvViewer = environment["ProgramFiles"].map {
            URL(fileURLWithPath: $0).appendingPathComponent("NICE/DCV/Client/bin/dcvviewer.exe").nativePath
        }
        return HelperServices(
            platform: platform, auth: ClientAuthProvider(openURL: { requests.openURL($0) }),
            ec2: ClientEC2Service(), ssm: ClientSSMService(), secrets: ClientSecretsService(),
            instanceConnect: ClientInstanceConnectService(),
            tunnel: ProcessTunnelProvider(pluginPath: { tools.pluginPath }),
            sshTunnel: ProcessSSHTunnel(sshPath: { tools.sshPath }, pluginPath: { tools.pluginPath }, style: .windows),
            keyGenerator: ProcessSSHKeyGenerator(keygenPath: { tools.sshKeygenPath }),
            dcv: ShellDCVLauncher(requests: requests, directory: local.appendingPathComponent("DCV", isDirectory: true),
                                  viewerInstalled: { dcvViewer.map { FileManager.default.fileExists(atPath: $0) } ?? false },
                                  writePrivate: { try WindowsPrivateFiles.write($0, to: $1) }),
            readiness: TLSReadinessProbe(), tunnelListener: TCPPortListenerProbe(),
            instanceIds: UserDefaultsInstanceIdStore(), keyValues: WindowsKeyValueStore(),
            profileFiles: PortableProfileFiles(replace: { try WindowsPrivateFiles.write($0, to: $1) }),
            pasteboard: ShellPasteboard(requests: requests), notifier: ShellNotifier(requests: requests),
            writePAC: { configuration, id in
                let url = local.appendingPathComponent("WebForwards/\(id.uuidString).pac")
                try WindowsPrivateFiles.write(Data(try WebForwardsPAC.contents(configuration: configuration).utf8), to: url)
                return url
            },
            editor: .init(root: local.appendingPathComponent("RemoteAccess", isDirectory: true),
                          sshConfig: home.appendingPathComponent(".ssh/config"),
                          helperPath: { tools.helperDirectory.appendingPathComponent("ssm-connect-proxy.exe").nativePath },
                          pluginPath: { tools.pluginPath }, editorPath: { tools.vsCodePath }, editorPreflight: { _ in },
                          owner: ProcessLeaseOwner(), sshAvailable: { tools.sshPath != nil && tools.sshKeygenPath != nil }),
            browserSupported: { profile in
                guard let choice = profile.webForwards?.browser, let mode = profile.webForwards?.browserMode else { return false }
                return WindowsBrowserDiscovery().supported(choice, mode: mode) != nil
            },
            requests: requests)
    }
    #endif
}
