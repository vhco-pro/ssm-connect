import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectMacOS
@testable import SSMConnectWorkflow

/// Covers the macOS shell's response to what the connection flow reports (§5.2, §7).
///
/// These assertions used to live in `ConnectionStateMachineTests`, against the flow itself. They
/// moved here with the behavior: the flow now reports a password and a lifecycle event, and this is
/// the thing that decides a password reaches the pasteboard and a notification gets posted. Keeping
/// them means the split did not quietly drop coverage — the same facts are still asserted, just
/// against whichever component is now responsible.
@Suite("MacConnectionEventSink")
@MainActor
struct MacConnectionEventSinkTests {
    private func makeSink(
        pasteboard: FakePasteboard = FakePasteboard(),
        notifier: MockNotifier = MockNotifier(),
        autoClearAfter: Duration? = nil
    ) -> (MacConnectionEventSink, FakePasteboard, MockNotifier) {
        let sink = MacConnectionEventSink(
            clipboard: ClipboardManager(pasteboard: pasteboard, autoClearAfter: autoClearAfter),
            notifier: notifier
        )
        return (sink, pasteboard, notifier)
    }

    @Test("a reported password reaches the pasteboard")
    func passwordIsCopied() {
        let (sink, pasteboard, _) = makeSink()

        sink.passwordAvailable("s3cr3t")

        #expect(pasteboard.currentString() == "s3cr3t")
    }

    @Test("a reported lifecycle event is posted as a notification")
    func notificationIsPosted() async {
        let (sink, _, notifier) = makeSink()

        sink.notify(.connected)

        // `notify` hands off to a Task so the flow never waits on the notification centre.
        await waitUntil { !notifier.events.isEmpty }
        #expect(notifier.events.contains(.connected))
    }

    @Test("notification authorization is requested by the shell, not by the flow")
    func authorizationIsRequested() async {
        let (sink, _, notifier) = makeSink()

        sink.requestNotificationAuthorization()

        await waitUntil { notifier.authorizationRequests >= 1 }
        #expect(notifier.authorizationRequests >= 1)
    }

    @Test("a settings change updates the clipboard retention without a restart")
    func settingsChangeUpdatesRetention() async {
        // The flow reports settings rather than acting on them, so this is the only place the
        // clipboard-retention preference takes effect. Before the split it was applied inside the
        // state machine's initializer and `apply(profile:settings:)`.
        let (sink, pasteboard, _) = makeSink(autoClearAfter: nil)

        sink.settingsChanged(AppSettings(autoConnect: false, autoReconnect: true, clipboardAutoClearSeconds: 0))
        sink.passwordAvailable("kept")
        #expect(pasteboard.currentString() == "kept")

        // A zero retention means "never clear", so the value survives.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(pasteboard.currentString() == "kept")
    }

    private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }
}
