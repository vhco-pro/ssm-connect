import SSMConnectWorkflow

/// The build identity the helper presents at handshake: the installation's build. The shell
/// refuses a helper whose build differs from its own.
enum HelperBuild {
    static let current = InstalledBuild.current
}
