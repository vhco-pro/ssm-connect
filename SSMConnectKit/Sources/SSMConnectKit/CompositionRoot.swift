import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectMacOS
import SSMConnectWorkflow

/// The macOS composition root (MR-03).
///
/// Every production adapter is named exactly once, here. The workflow's own initializer takes its
/// ports as required arguments and knows none of these types — that is what lets
/// `SSMConnectWorkflow` compile without AppKit or an AWS SDK, and it is why this file exists in the
/// umbrella target rather than next to the state machine.
public extension ConnectionStateMachine {
    /// A state machine for a profile + settings, wired with the production adapters.
    ///
    /// Also registers the app-quit hook. Killing the plugin child on quit is macOS lifecycle
    /// policy rather than a connection rule (MR-04), so it belongs to the composition root — which
    /// additionally keeps every test-constructed machine from mutating a global singleton.
    convenience init(profile: ConnectionProfile, settings: AppSettings) {
        let sink = MacConnectionEventSink()
        self.init(
            authProvider: AWSAuthProvider(),
            ec2: EC2Service(),
            ssm: SSMService(),
            tunnel: BundledPluginTunnel(),
            secrets: SecretsService(),
            identity: STSIdentityProvider(),
            agent: HTTPAgentClient(),
            dcv: DCVLauncher(),
            readiness: HTTPSReadinessProbe(),
            tunnelListener: TCPListenerProbe(),
            instanceIds: UserDefaultsInstanceIdStore(),
            terminateProcess: PluginProcessTerminator.signalSequence,
            // Mirrors the in-memory ring buffer to Apple Unified Logging (NF-14).
            log: ConnectionLog(sink: OSLogSink()),
            events: sink,
            profile: profile,
            settings: settings,
            timeouts: .default,
            // Without this the app would render AWS SDK failures as "Smithy.ClientError error 4".
            errorInterpreter: AWSErrorInterpreter()
        )
        // Notification permission is an app-lifecycle concern, so it is requested here rather
        // than by the connection flow on launch.
        sink.requestNotificationAuthorization()
        AppQuitHandler.shared.register { [weak self] in self?.terminateTunnelForQuit() }
    }
}
