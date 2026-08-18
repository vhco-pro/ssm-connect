import Foundation

/// SSM document names the clients invoke.
///
/// A wire constant rather than an implementation detail: `SSMService` names it when starting the
/// session and the plugin adapter repeats it in the argument JSON it hands the
/// `session-manager-plugin`. It lives in the domain so neither adapter has to depend on the other,
/// and so the Windows client pins the same string.
public enum SSMDocument {
    /// The AWS-managed document that opens a port-forwarding session.
    public static let portForward = "AWS-StartPortForwardingSession"
}
