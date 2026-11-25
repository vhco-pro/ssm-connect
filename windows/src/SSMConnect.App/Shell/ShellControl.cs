namespace SSMConnect.App.Shell;

/// <summary>
/// One control of the macOS interface the Windows shell offers (contracts/macos-parity.json, AC-29): its
/// inventory id, where it appears, the helper command it sends (or a cancel of its workflow's running
/// command, or none for a shell-only control), macOS's confirmation, and when macOS offers and enables it.
/// </summary>
public sealed record ShellControl(
    string Id, string Surface, string Label, string Command, IReadOnlyList<string> Commands, string CancelWorkflow, string Otherwise,
    string Shell, string Field, string ConfirmTitle, string ConfirmText, string ConfirmWhen, IReadOnlyList<string> Choices,
    string OfferedWhen, string EnabledWhen);
