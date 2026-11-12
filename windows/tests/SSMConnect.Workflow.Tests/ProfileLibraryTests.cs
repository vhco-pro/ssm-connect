using System.Text.Json.Nodes;
using SSMConnect.Domain;

namespace SSMConnect.Workflow.Tests;

public sealed class ProfileLibraryTests
{
    private static readonly IReadOnlySet<string> Supported = new HashSet<string> { "tunnelOnly" };

    private static ConnectionProfile Profile() => new()
    {
        Id = Guid.NewGuid(), Name = "Example", SsoStartUrl = "https://d-0000000000.awsapps.com/start",
        SsoRegion = "eu-west-1", AccountId = "000000000000", RoleName = "ExampleWorkstationRole",
        ResourceRegion = "eu-central-1", InstanceTagKey = "Name", InstanceTagValue = "example-workstation",
        LocalPort = 8443, RemotePort = 8443, ConnectAction = ConnectAction.TunnelOnly,
    };

    [Fact]
    public void Cfg11PreviewImportAndAttachNeverWriteTheSource()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile profile = library.Import(preview, attach: true);
        Assert.NotEqual(preview.Document.Id, profile.Id);
        Assert.Equal(0, files.SaveCount);
        Assert.Equal(preview.Revision, files.Read("profile.yaml").Revision);
        Assert.Single(library.Attachments);
        library.Detach(profile.Id);
        Assert.Single(library.Profiles);
        Assert.Empty(library.Attachments);
        Assert.Equal(0, files.SaveCount);
    }

    [Fact]
    public void Cfg04CanonicalGuiSavePreservesDocumentAndUnknownValues()
    {
        var files = new MemoryProfileFiles();
        PortableProfileDocument document = PortableProfileDocument.FromProfile(Profile()) with
        {
            UnknownFields = new Dictionary<string, JsonNode?> { ["futureOption"] = JsonValue.Create("retain") },
        };
        ProfileFileSnapshot preview = files.Put("profile.yaml", document);
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile profile = library.Import(preview, attach: true) with { Name = "GUI edit" };
        Assert.Throws<ProfilePortabilityException>(() => library.SaveProfile(profile, preview.Revision, false));
        library.SaveProfile(profile, preview.Revision, true);
        Assert.Equal("GUI edit", library.Profiles.Single().Name);
        Assert.Equal(document.Id, files.Read("profile.yaml").Document.Id);
        Assert.Equal("retain", library.Export(profile.Id).UnknownFields["futureOption"]!.GetValue<string>());
        Assert.True(library.Attachments[profile.Id].CanonicalSaveAccepted);
        var reloaded = new ProfileLibrary(library.Profiles, files, Supported, library.Documents, library.Attachments);
        Assert.Equal(profile.Id, reloaded.Profiles.Single().Id);
        Assert.Equal(document.Id, reloaded.Export(profile.Id).Id);
    }

    [Fact]
    public void Cfg05ExternalEditsAreStagedUntilExplicitApply()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        files.Put("profile.yaml", preview.Document.WithProfile(original with { InstanceTagValue = "other-target" }));
        library.Refresh();
        Assert.Equal(original, library.Profiles.Single());
        Assert.Single(library.Pending);
        library.Apply(original.Id);
        Assert.Equal("other-target", library.Profiles.Single().InstanceTagValue);
        Assert.Equal(original.Id, library.Profiles.Single().Id);
        Assert.Equal(0, files.SaveCount);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void Cfg06InvalidOrMissingFileRetainsLastGoodConfiguration(bool missing)
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        files.Failure = missing ? new FileNotFoundException("Missing") : new ProfilePortabilityException("Invalid YAML");
        library.Refresh();
        Assert.Equal(original, library.Profiles.Single());
        Assert.Single(library.Errors);
        Assert.Empty(library.Pending);
        ConnectionProfile copy = library.SaveLocalCopy(original, original.Id);
        Assert.NotEqual(original.Id, copy.Id);
        Assert.False(library.Attachments.ContainsKey(copy.Id));
        Assert.Equal(0, files.SaveCount);
    }

    [Fact]
    public void Cfg06ReadOnlyFileOffersIndependentCopyWithoutWriting()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()), canWrite: false);
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        Assert.Throws<UnauthorizedAccessException>(() => library.SaveProfile(original, preview.Revision, true));
        Assert.Equal(original, library.Profiles.Single());
        ConnectionProfile copy = library.SaveLocalCopy(original with { Name = "Draft" }, original.Id);
        Assert.Equal("Draft Copy", copy.Name);
        Assert.Equal(0, files.SaveCount);
    }

    [Fact]
    public void Cfg07ExternalSaveRacesAreRefusedAndGuiDraftSurvives()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        ConnectionProfile draft = original with { Name = "GUI draft" };
        files.BeforeCommit = () => files.Put("profile.yaml", preview.Document.WithProfile(original with { Name = "External" }));
        Assert.Throws<ProfileFileConflictException>(() => library.SaveProfile(draft, preview.Revision, true));
        Assert.Equal("External", files.Read("profile.yaml").Document.Name);
        Assert.Equal(original, library.Profiles.Single());
        Assert.Equal("GUI draft Copy", library.SaveLocalCopy(draft, original.Id).Name);
        Assert.Equal(0, files.SaveCount);
    }

    [Fact]
    public void Cfg08PortableIdentityCollisionCannotInheritLocalOwnership()
    {
        ConnectionProfile existing = Profile();
        var files = new MemoryProfileFiles();
        PortableProfileDocument document = PortableProfileDocument.FromProfile(existing);
        ProfileFileSnapshot preview = files.Put("first.yaml", document);
        var library = new ProfileLibrary([existing], files, Supported);
        ConnectionProfile first = library.Import(preview, true);
        Assert.NotEqual(existing.Id, first.Id);
        Assert.Throws<ProfilePortabilityException>(() => library.Import(preview, true));
        ConnectionProfile second = library.Import(files.Put("second.yaml", document), true);
        Assert.NotEqual(first.Id, second.Id);
        Assert.Equal(existing, library.Profiles[0]);
    }

    [Fact]
    public void Cfg08ChangedDocumentIdentityCannotReplaceAnAttachedProfile()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        files.Put("profile.yaml", preview.Document with { Id = Guid.NewGuid() });
        library.Refresh();
        Assert.Single(library.Errors);
        Assert.Empty(library.Pending);
        Assert.Equal(original, library.Profiles.Single());
    }

    [Fact]
    public void Cfg10UnsupportedRequiredCapabilityCannotBeSilentlyImported()
    {
        var files = new MemoryProfileFiles();
        ConnectionProfile profile = Profile() with { WebForwards = new WebForwardsConfiguration { Enabled = true } };
        ProfileFileSnapshot preview = files.Put("profile.yaml", PortableProfileDocument.FromProfile(profile));
        var library = new ProfileLibrary([], files, Supported);
        Assert.Throws<ProfilePortabilityException>(() => library.Import(preview, true));
        Assert.Empty(library.Profiles);
        Assert.Empty(library.Attachments);
        Assert.Equal(0, files.SaveCount);
    }

    [Fact]
    public void Cfg06LocateStagesTheSameDocumentWithoutApplyingIt()
    {
        var files = new MemoryProfileFiles();
        ProfileFileSnapshot preview = files.Put("original.yaml", PortableProfileDocument.FromProfile(Profile()));
        var library = new ProfileLibrary([], files, Supported);
        ConnectionProfile original = library.Import(preview, true);
        files.Put("moved.yaml", preview.Document.WithProfile(original with { Name = "Moved" }));
        library.Locate(original.Id, "moved.yaml");
        Assert.Equal(original, library.Profiles.Single());
        Assert.Single(library.Pending);
        library.Apply(original.Id);
        Assert.Equal("Moved", library.Profiles.Single().Name);
    }

    private sealed class MemoryProfileFiles : IProfileFiles
    {
        private readonly Dictionary<string, ProfileFileSnapshot> _files = new(StringComparer.OrdinalIgnoreCase);
        private int _generation;
        public int SaveCount { get; private set; }
        public Exception? Failure { get; set; }
        public Action? BeforeCommit { get; set; }

        public ProfileFileSnapshot Put(string path, PortableProfileDocument document, bool canWrite = true)
        {
            _ = ProfilePortability.Import(ProfilePortability.Export(document));
            var revision = new ProfileFileRevision((++_generation).ToString(), path, "user-only", 0, _generation);
            var snapshot = new ProfileFileSnapshot(path, document, revision, canWrite);
            _files[path] = snapshot;
            return snapshot;
        }
        public ProfileFileSnapshot Read(string path) => Failure is null ? _files[path] : throw Failure;
        public ProfileFileRevision? ExistingRevision(string path) => _files.GetValueOrDefault(path)?.Revision;
        public ProfileFileRevision Save(PortableProfileDocument document, string path, ProfileFileRevision? expected)
        {
            if (!Read(path).CanWrite) { throw new UnauthorizedAccessException("Read-only profile"); }
            if (ExistingRevision(path) != expected) { throw new ProfileFileConflictException(); }
            BeforeCommit?.Invoke();
            if (ExistingRevision(path) != expected) { throw new ProfileFileConflictException(); }
            ProfileFileSnapshot written = Put(path, document);
            SaveCount++;
            return written.Revision;
        }
    }
}
