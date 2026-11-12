using System.Runtime.Versioning;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;
using SSMConnect.Domain;
using SSMConnect.Workflow;

namespace SSMConnect.Windows;

/// <summary>What the client persists: profiles and settings, kept in separate documents.</summary>
/// <remarks>
/// Settings are global, not per profile. That is a contract decision, not an implementation detail:
/// specification §15 question 6 settled schema v1 as carrying connection profiles only, and the
/// macOS client stores its settings under a separate key for the same reason.
/// </remarks>
public sealed record StoredState(IReadOnlyList<ConnectionProfile> Profiles, AppSettings Settings, Guid? ActiveProfileId,
    IReadOnlyDictionary<Guid, PortableProfileDocument>? Documents = null,
    IReadOnlyDictionary<Guid, ProfileAttachment>? Attachments = null);

/// <summary>
/// Persists profiles and settings under the user's local application data.
/// </summary>
/// <remarks>
/// Never stores credentials, tokens, or the DCV password. A profile carries a Secrets Manager
/// identifier; the value it names stays in AWS.
/// </remarks>
public sealed class ProfileStore
{
    private static readonly JsonSerializerOptions Options = new()
    {
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter() },
    };

    private readonly string _profilesPath;
    private readonly string _settingsPath;

    public ProfileStore(string? directory = null)
    {
        string root = directory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SSM Connect");
        _profilesPath = Path.Combine(root, "profiles.v1.json");
        _settingsPath = Path.Combine(root, "settings.v1.json");
    }

    public StoredState Load()
    {
        ProfilesDocument profiles = Read<ProfilesDocument>(_profilesPath) ?? new ProfilesDocument([], null);
        AppSettings settings = Read<AppSettings>(_settingsPath) ?? AppSettings.Default;
        if (profiles.Profiles is null)
        {
            throw new ProfilePortabilityException("Saved profiles are missing their profile list. Restore the original file before starting.");
        }
        return new StoredState(profiles.Profiles, settings, profiles.ActiveProfileId, profiles.Documents, profiles.Attachments);
    }

    public void Save(StoredState state)
    {
        Write(_profilesPath, new ProfilesDocument([.. state.Profiles], state.ActiveProfileId, state.Documents, state.Attachments));
        Write(_settingsPath, state.Settings);
    }

    private static T? Read<T>(string path)
        where T : class
    {
        try
        {
            return JsonSerializer.Deserialize<T>(File.ReadAllText(path), Options)
                ?? throw new ProfilePortabilityException("Saved configuration is empty. Restore it before starting; the original file was retained.");
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (JsonException)
        {
            throw new ProfilePortabilityException(
                "Saved configuration could not be read. Restore or repair it before starting; the original file was retained.");
        }
    }

    private static void Write<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        string temporary = path + ".tmp-" + Guid.NewGuid().ToString("N");
        try
        {
            File.WriteAllText(temporary, JsonSerializer.Serialize(value, Options));
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) { File.Delete(temporary); } }
    }

    private sealed record ProfilesDocument(IReadOnlyList<ConnectionProfile> Profiles, Guid? ActiveProfileId,
        IReadOnlyDictionary<Guid, PortableProfileDocument>? Documents = null,
        IReadOnlyDictionary<Guid, ProfileAttachment>? Attachments = null);
}

/// <summary>
/// Registers the app to start at sign-in, through the per-user Run key.
/// </summary>
/// <remarks>
/// Per-user and non-elevated, matching the installer. The Run key is the supported mechanism for a
/// per-user installed desktop app; a scheduled task or an all-users key would both need elevation
/// the app deliberately does not request.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class StartupRegistration(string valueName = "SSM Connect", string? executablePath = null)
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    private readonly string _executablePath = executablePath ?? Environment.ProcessPath ?? string.Empty;

    public bool IsEnabled
    {
        get
        {
            using RegistryKey? key = Registry.CurrentUser.OpenSubKey(RunKeyPath);
            return key?.GetValue(valueName) is string value && value.Length > 0;
        }
    }

    public void SetEnabled(bool enabled)
    {
        using RegistryKey key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
        if (!enabled)
        {
            key.DeleteValue(valueName, throwOnMissingValue: false);
            return;
        }

        if (_executablePath.Length == 0)
        {
            throw new InvalidOperationException("The executable path could not be resolved.");
        }

        // Quoted: the install path contains a space, and an unquoted Run value would be parsed as
        // an executable plus arguments.
        key.SetValue(valueName, $"\"{_executablePath}\"", RegistryValueKind.String);
    }
}

/// <summary>
/// Clipboard policy for the DCV password: copy on request, clear automatically after a delay.
/// </summary>
/// <remarks>
/// This is shell policy and deliberately lives outside the workflow, which only reports that a
/// password became available. Auto-clear exists because the password reaches the clipboard at all.
/// </remarks>
public sealed class ClipboardPolicy(Action<string> copy, Action clear, Func<TimeSpan, CancellationToken, Task>? delay = null)
{
    private readonly Func<TimeSpan, CancellationToken, Task> _delay =
        delay ?? ((duration, token) => Task.Delay(duration, token));

    private CancellationTokenSource? _pending;

    /// <summary>Copies the value, scheduling a clear unless the delay is zero, which disables it.</summary>
    public void Copy(string value, int autoClearSeconds)
    {
        copy(value);

        _pending?.Cancel();
        _pending?.Dispose();
        _pending = null;

        if (autoClearSeconds <= 0)
        {
            return;
        }

        var source = new CancellationTokenSource();
        _pending = source;

        _ = Task.Run(async () =>
        {
            try
            {
                await _delay(TimeSpan.FromSeconds(autoClearSeconds), source.Token).ConfigureAwait(false);
                clear();
            }
            catch (OperationCanceledException)
            {
                // A newer copy superseded this one; it owns the clipboard and its own timer.
            }
        });
    }

    /// <summary>Cancels any pending clear, for shutdown.</summary>
    public void Cancel()
    {
        _pending?.Cancel();
        _pending?.Dispose();
        _pending = null;
    }
}
