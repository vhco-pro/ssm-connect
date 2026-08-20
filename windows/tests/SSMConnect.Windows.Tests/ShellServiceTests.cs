using SSMConnect.Domain;
using SSMConnect.Windows;

namespace SSMConnect.Windows.Tests;

public sealed class ProfileStoreTests
{
    private static ConnectionProfile Example(string name) => new()
    {
        Id = Guid.NewGuid(),
        Name = name,
        SsoStartUrl = "https://d-0000000000.awsapps.com/start",
        SsoRegion = "eu-west-1",
        AccountId = "000000000000",
        RoleName = "ExampleRole",
        ResourceRegion = "eu-central-1",
        InstanceTagKey = "Name",
        InstanceTagValue = "example-workstation",
        LocalPort = 8443,
        RemotePort = 8443,
        SecretId = "example/dcv/password",
    };

    private static string TempDirectory() =>
        Path.Combine(Path.GetTempPath(), $"ssm-connect-store-{Guid.NewGuid():N}");

    [Fact]
    public void RoundTripsProfilesAndSettings()
    {
        string directory = TempDirectory();
        try
        {
            ConnectionProfile first = Example("First");
            ConnectionProfile second = Example("Second") with { ConnectMode = ConnectMode.MultiUser, SecretId = null };
            var settings = new AppSettings { AutoConnect = true, AutoReconnect = false, ClipboardAutoClearSeconds = 15 };

            new ProfileStore(directory).Save(new StoredState([first, second], settings, first.Id));
            StoredState loaded = new ProfileStore(directory).Load();

            Assert.Equal(2, loaded.Profiles.Count);
            Assert.Equal(first.Id, loaded.ActiveProfileId);
            Assert.Equal("First", loaded.Profiles[0].Name);
            Assert.Equal(ConnectMode.MultiUser, loaded.Profiles[1].ConnectMode);
            Assert.Equal(settings, loaded.Settings);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>
    /// Settings live in their own document. Folding them into a profile would contradict the
    /// contract decision that schema v1 carries connection profiles only.
    /// </summary>
    [Fact]
    public void KeepsSettingsInASeparateDocumentFromProfiles()
    {
        string directory = TempDirectory();
        try
        {
            new ProfileStore(directory).Save(
                new StoredState([Example("Only")], AppSettings.Default with { AutoConnect = true }, null));

            string profiles = File.ReadAllText(Path.Combine(directory, "profiles.v1.json"));
            string settings = File.ReadAllText(Path.Combine(directory, "settings.v1.json"));

            Assert.DoesNotContain("autoConnect", profiles, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("AutoConnect", settings, StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    /// <summary>Persisted state must never contain authentication material.</summary>
    [Fact]
    public void StoresTheSecretIdentifierButNeverASecretValue()
    {
        string directory = TempDirectory();
        try
        {
            new ProfileStore(directory).Save(new StoredState([Example("Only")], AppSettings.Default, null));
            string profiles = File.ReadAllText(Path.Combine(directory, "profiles.v1.json"));

            Assert.Contains("example/dcv/password", profiles, StringComparison.Ordinal);
            foreach (string forbidden in ProfilePortability.ForbiddenKeys)
            {
                Assert.DoesNotContain($"\"{forbidden}\"", profiles, StringComparison.OrdinalIgnoreCase);
            }
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    [Fact]
    public void StartsEmptyWhenNothingHasBeenSaved()
    {
        StoredState loaded = new ProfileStore(TempDirectory()).Load();
        Assert.Empty(loaded.Profiles);
        Assert.Equal(AppSettings.Default, loaded.Settings);
        Assert.Null(loaded.ActiveProfileId);
    }

    /// <summary>A corrupt file must not stop the app from starting.</summary>
    [Fact]
    public void SurvivesACorruptDocument()
    {
        string directory = TempDirectory();
        try
        {
            Directory.CreateDirectory(directory);
            File.WriteAllText(Path.Combine(directory, "profiles.v1.json"), "{ this is not json");

            StoredState loaded = new ProfileStore(directory).Load();
            Assert.Empty(loaded.Profiles);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }
}

public sealed class StartupRegistrationTests
{
    /// <summary>
    /// Uses a test-specific value name so the developer's own startup entry is never touched.
    /// </summary>
    [Fact]
    public void EnablesAndDisablesThePerUserStartupEntry()
    {
        string valueName = $"SSM Connect Test {Guid.NewGuid():N}";
        var registration = new StartupRegistration(valueName, @"C:\Program Files\Example\SSM Connect.exe");

        try
        {
            Assert.False(registration.IsEnabled);

            registration.SetEnabled(true);
            Assert.True(registration.IsEnabled);

            registration.SetEnabled(false);
            Assert.False(registration.IsEnabled);
        }
        finally
        {
            registration.SetEnabled(false);
        }
    }

    /// <summary>
    /// The install path contains a space, so an unquoted value would be parsed as an executable
    /// plus arguments and silently fail to launch.
    /// </summary>
    [Fact]
    public void QuotesThePathSoASpaceDoesNotSplitIt()
    {
        string valueName = $"SSM Connect Test {Guid.NewGuid():N}";
        const string path = @"C:\Users\example\AppData\Local\Programs\SSM Connect\SSMConnect.exe";
        var registration = new StartupRegistration(valueName, path);

        try
        {
            registration.SetEnabled(true);
            using Microsoft.Win32.RegistryKey key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Run")!;
            Assert.Equal($"\"{path}\"", key.GetValue(valueName));
        }
        finally
        {
            registration.SetEnabled(false);
        }
    }

    [Fact]
    public void DisablingWhenAlreadyDisabledIsHarmless()
    {
        var registration = new StartupRegistration($"SSM Connect Test {Guid.NewGuid():N}", @"C:\x.exe");
        registration.SetEnabled(false);
        Assert.False(registration.IsEnabled);
    }
}

public sealed class ClipboardPolicyTests
{
    [Fact]
    public async Task ClearsTheClipboardAfterTheConfiguredDelay()
    {
        var copied = new List<string>();
        var cleared = 0;
        TaskCompletionSource waited = new(TaskCreationOptions.RunContinuationsAsynchronously);

        var policy = new ClipboardPolicy(
            copied.Add,
            () => Interlocked.Increment(ref cleared),
            async (duration, token) =>
            {
                waited.TrySetResult();
                await Task.Delay(1, token);
            });

        policy.Copy("synthetic-password", autoClearSeconds: 30);
        await waited.Task.WaitAsync(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken);
        await Task.Delay(100, TestContext.Current.CancellationToken);

        Assert.Equal(["synthetic-password"], copied);
        Assert.Equal(1, Volatile.Read(ref cleared));
    }

    /// <summary>Zero disables auto-clear, which is the documented meaning of the setting.</summary>
    [Fact]
    public async Task ZeroSecondsDisablesTheAutomaticClear()
    {
        var cleared = 0;
        var scheduled = false;

        var policy = new ClipboardPolicy(
            _ => { },
            () => Interlocked.Increment(ref cleared),
            (duration, token) => { scheduled = true; return Task.CompletedTask; });

        policy.Copy("synthetic-password", autoClearSeconds: 0);
        await Task.Delay(100, TestContext.Current.CancellationToken);

        Assert.False(scheduled);
        Assert.Equal(0, Volatile.Read(ref cleared));
    }

    /// <summary>
    /// A second copy must not have the first copy's timer wipe it: the clipboard would clear early
    /// and the user would think the copy failed.
    /// </summary>
    [Fact]
    public async Task ASecondCopyCancelsTheFirstPendingClear()
    {
        var cleared = 0;
        var policy = new ClipboardPolicy(
            _ => { },
            () => Interlocked.Increment(ref cleared),
            async (duration, token) => await Task.Delay(200, token));

        policy.Copy("first", autoClearSeconds: 30);
        await Task.Delay(50, TestContext.Current.CancellationToken);
        policy.Copy("second", autoClearSeconds: 30);
        await Task.Delay(120, TestContext.Current.CancellationToken);

        // The first timer was cancelled, so nothing has cleared yet.
        Assert.Equal(0, Volatile.Read(ref cleared));

        await Task.Delay(200, TestContext.Current.CancellationToken);
        Assert.Equal(1, Volatile.Read(ref cleared));
    }

    [Fact]
    public async Task CancelStopsAPendingClearAtShutdown()
    {
        var cleared = 0;
        var policy = new ClipboardPolicy(
            _ => { },
            () => Interlocked.Increment(ref cleared),
            async (duration, token) => await Task.Delay(150, token));

        policy.Copy("synthetic", autoClearSeconds: 30);
        policy.Cancel();
        await Task.Delay(250, TestContext.Current.CancellationToken);

        Assert.Equal(0, Volatile.Read(ref cleared));
    }
}

public sealed class ConnectionLogTests
{
    [Fact]
    public void KeepsWhatTheWorkflowReported()
    {
        var log = new ConnectionLog();
        log.Append("ssm", "SSM agent is online.");
        log.Append("tunnel", "Connected.");

        IReadOnlyList<LogEntry> entries = log.Snapshot();
        Assert.Equal(2, entries.Count);
        Assert.Equal("ssm", entries[0].Category);
        Assert.Equal("Connected.", entries[1].Message);
    }

    /// <summary>
    /// A tray app runs for days and the workflow logs every poll and retry, so an unbounded buffer
    /// is a slow leak. Oldest entries go first.
    /// </summary>
    [Fact]
    public void DropsTheOldestOnceFull()
    {
        var log = new ConnectionLog(capacity: 3);
        foreach (int i in Enumerable.Range(1, 5))
        {
            log.Append("ui", $"line {i}");
        }

        IReadOnlyList<LogEntry> entries = log.Snapshot();
        Assert.Equal(3, entries.Count);
        Assert.Equal("line 3", entries[0].Message);
        Assert.Equal("line 5", entries[2].Message);
    }

    [Fact]
    public void NotifiesAListenerSoAWindowCanFollowAlong()
    {
        var log = new ConnectionLog();
        var seen = new List<string>();
        log.Appended += entry => seen.Add(entry.Message);

        log.Append("auth", "Authenticated.");

        Assert.Equal(["Authenticated."], seen);
    }

    [Fact]
    public void RendersPlainTextForPasting()
    {
        var log = new ConnectionLog();
        log.Append("ec2", "Resolved instance i-0aaaaaaaaaaaaaaa1.");

        string text = log.ToPlainText();
        Assert.Contains("SSM Connect log", text, StringComparison.Ordinal);
        Assert.Contains("Resolved instance i-0aaaaaaaaaaaaaaa1.", text, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsANonPositiveCapacity() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new ConnectionLog(0));
}
