import Foundation
import SSMConnectDomain

/// Everything the connection flow wants the shell to do, and the flow's observable output (§7).
///
/// This is the `EventSink` port of `contracts/state-machine.schema.json`, and the Swift counterpart
/// of .NET's `IEventSink`. It exists because §5.2 says the workflow must not "open browsers, update
/// clipboards, post notifications, or send operating-system signals directly" — and before this it
/// did two of those: it called `ClipboardManager.copy` when a secret arrived and posted
/// notifications at each lifecycle event. Injecting those adapters made it testable but did not
/// make it portable: deciding *that* a password goes on the clipboard is shell policy, and a
/// platform without one still has to compile.
///
/// So the flow now reports what happened and the shell decides what to do about it. That also makes
/// the two clients agree: `EventSink` was previously real on .NET and absent on Swift, which left
/// the contract naming a port only one implementation had.
///
/// Every method is `@MainActor` and synchronous. The flow calls them from its own actor at moments
/// where ordering matters — a state change must be observed before the next port call — so a sink
/// that needs to do async work should hand it off rather than make callers wait.
@MainActor
public protocol ConnectionEventSink: AnyObject {
    /// A distinct state transition. Consecutive duplicates are not reported.
    func stateChanged(_ state: ConnectionState)

    /// A lifecycle moment worth surfacing to the user however the platform does that.
    func notify(_ event: NotificationEvent)

    /// The retrieved DCV password. The shell decides clipboard policy, including whether to copy it
    /// at all and when to clear it. Never persisted by anyone.
    func passwordAvailable(_ password: String)

    /// The active settings, at startup and whenever they change. The flow does not act on the
    /// clipboard-retention preference itself; it reports it so the shell that owns the clipboard
    /// can honour a change without waiting for a restart.
    func settingsChanged(_ settings: AppSettings)
}

/// A sink that does nothing. The default, so the flow is constructible — and runnable under the
/// conformance fixtures — with no shell attached.
public final class NoopEventSink: ConnectionEventSink {
    public init() {}
    public func stateChanged(_ state: ConnectionState) {}
    public func notify(_ event: NotificationEvent) {}
    public func passwordAvailable(_ password: String) {}
    public func settingsChanged(_ settings: AppSettings) {}
}
