/// The build identity the helper presents at handshake. The shell refuses a helper whose build
/// differs from its own; the release jobs stamp both with the same value.
enum HelperBuild {
    static let current = "dev"
}
