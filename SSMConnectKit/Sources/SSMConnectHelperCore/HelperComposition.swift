import Foundation
import SSMConnectAWS
import SSMConnectAWSClient
import SSMConnectDomain
import SSMConnectWorkflow
#if os(Windows)
import SSMConnectWindows
import WinSDK
#elseif os(Linux)
import Glibc
import SSMConnectLinux
#endif

/// The helper's production services on Windows and Linux: SSM Connect's AWS client services and
/// SSO provider, the platform's adapters, and the installation check of the exact plugin and
/// editor proxy files before each launch. Elsewhere the helper is not shipped and has no
/// production composition.
package enum HelperComposition {
    #if os(Windows) || os(Linux)
    /// What differs between the two platforms; everything else is composed once below.
    struct Adapters {
        var local: URL
        var home: URL
        var pluginPath: @Sendable () -> String?
        var proxyPath: @Sendable () -> String
        var sshPath: @Sendable () -> String?
        var vsCodePath: @Sendable () -> String?
        var dcvViewerPath: @Sendable () -> String?
        var sshStyle: SSHArguments.Style
        var ownerOnlyFiles: OwnerOnlyFiles
        var writePrivate: @Sendable (Data, URL) throws -> Void
        var keyValues: KeyValueStoring
        var terminateChildProcess: @Sendable (Int32) -> Void
        var browserSupported: @Sendable (ManagedBrowserChoice, BrowserMode) -> Bool
    }

    #if os(Windows)
    static func adapters() -> Adapters {
        let tools = WindowsTools()
        let environment = ProcessInfo.processInfo.environment
        return Adapters(
            local: URL(fileURLWithPath: environment["LOCALAPPDATA"] ?? NSTemporaryDirectory())
                .appendingPathComponent("SSM Connect", isDirectory: true),
            home: URL(fileURLWithPath: environment["USERPROFILE"] ?? NSHomeDirectory()),
            pluginPath: { tools.pluginPath },
            proxyPath: { tools.helperDirectory.appendingPathComponent("ssm-connect-proxy.exe").nativePath },
            sshPath: { tools.sshPath }, vsCodePath: { tools.vsCodePath },
            dcvViewerPath: { tools.dcvViewerPath },
            sshStyle: .windows, ownerOnlyFiles: .windows,
            writePrivate: { try WindowsPrivateFiles.write($0, to: $1) },
            keyValues: WindowsKeyValueStore.make(),
            terminateChildProcess: { pid in
                guard let process = OpenProcess(DWORD(PROCESS_TERMINATE), false, DWORD(pid)) else { return }
                TerminateProcess(process, 1)
                CloseHandle(process)
            },
            browserSupported: { WindowsBrowserDiscovery().supported($0, mode: $1) != nil })
    }
    #else
    static func adapters() -> Adapters {
        let tools = LinuxTools()
        let paths = LinuxPaths()
        return Adapters(
            local: paths.state, home: paths.home,
            pluginPath: { tools.pluginPath },
            proxyPath: { tools.helperDirectory.appendingPathComponent("ssm-connect-proxy").path },
            sshPath: { tools.sshPath }, vsCodePath: { tools.vsCodePath },
            dcvViewerPath: { tools.dcvViewerPath },
            sshStyle: .posix, ownerOnlyFiles: .posix,
            writePrivate: { try LinuxPrivateFiles.write($0, to: $1) },
            keyValues: LinuxKeyValueStore.make(paths: paths),
            terminateChildProcess: { pid in
                guard pid > 0 else { return }
                kill(pid, SIGTERM)
                usleep(300_000) // 0.3 s grace, as on macOS
                kill(pid, SIGKILL)
            },
            browserSupported: { LinuxBrowserDiscovery().supported($0, mode: $1) != nil })
    }
    #endif

    @MainActor package static func production(requests: ShellRequests) -> HelperServices {
        let adapters = adapters()
        let check = InstallationCheck()
        let local = adapters.local
        let writePrivate = adapters.writePrivate
        let platform = WorkflowPlatform(
            terminateChildProcess: adapters.terminateChildProcess,
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
            ownerOnlyFiles: adapters.ownerOnlyFiles)
        let proxyPath = adapters.proxyPath
        let sshPath = adapters.sshPath
        let dcvViewerPath = adapters.dcvViewerPath
        let browserSupported = adapters.browserSupported
        return HelperServices(
            platform: platform, auth: ClientAuthProvider(openURL: { requests.openURL($0) }),
            ec2: ClientEC2Service(), ssm: ClientSSMService(), secrets: ClientSecretsService(),
            instanceConnect: ClientInstanceConnectService(),
            tunnel: ProcessTunnelProvider(pluginPath: adapters.pluginPath, verify: { try check.plugin(at: $0) }),
            sshTunnel: ProcessSSHTunnel(sshPath: sshPath, pluginPath: adapters.pluginPath, style: adapters.sshStyle,
                                        verify: { try check.plugin(at: $0) }),
            keyGenerator: NativeSSHKeyGenerator(),
            dcv: ShellDCVLauncher(requests: requests, directory: local.appendingPathComponent("DCV", isDirectory: true),
                                  viewerInstalled: { dcvViewerPath() != nil }, writePrivate: writePrivate),
            readiness: TLSReadinessProbe(), tunnelListener: TCPPortListenerProbe(),
            instanceIds: UserDefaultsInstanceIdStore(), keyValues: adapters.keyValues,
            profileFiles: PortableProfileFiles(replace: writePrivate),
            pasteboard: ShellPasteboard(requests: requests), notifier: ShellNotifier(requests: requests),
            writePAC: { configuration, id in
                let url = local.appendingPathComponent("WebForwards/\(id.uuidString).pac")
                try writePrivate(Data(try WebForwardsPAC.contents(configuration: configuration).utf8), url)
                return url
            },
            editor: .init(root: local.appendingPathComponent("RemoteAccess", isDirectory: true),
                          sshConfig: adapters.home.appendingPathComponent(".ssh/config"),
                          helperPath: proxyPath, pluginPath: adapters.pluginPath, editorPath: adapters.vsCodePath,
                          // VS Code starts the proxy, which starts the plugin: both must be this build's.
                          editorPreflight: { _ in
                              try check.executable(at: proxyPath())
                              if let plugin = adapters.pluginPath() { try check.plugin(at: plugin) }
                          },
                          owner: ProcessLeaseOwner(), sshAvailable: { sshPath() != nil }),
            browserSupported: { profile in
                guard let choice = profile.webForwards?.browser, let mode = profile.webForwards?.browserMode else { return false }
                return browserSupported(choice, mode)
            },
            requests: requests)
    }
    #endif
}
