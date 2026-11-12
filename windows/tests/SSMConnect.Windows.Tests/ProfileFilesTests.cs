using System.Security.AccessControl;
using System.Security.Principal;
using System.Runtime.CompilerServices;
using SSMConnect.Domain;
using SSMConnect.Workflow;

namespace SSMConnect.Windows.Tests;

public sealed class NativeWindowsFactAttribute : FactAttribute
{
    public NativeWindowsFactAttribute([CallerFilePath] string? sourceFilePath = null,
        [CallerLineNumber] int sourceLineNumber = -1) : base(sourceFilePath, sourceLineNumber)
    {
        if (!OperatingSystem.IsWindows()) { Skip = "Requires native Windows file identity, ACL and rename behavior."; }
    }
}

public sealed class ProfileFilesTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "ssm-profile-files-" + Guid.NewGuid().ToString("N"));
    private string PathFor(string name) => Path.Combine(_root, name);
    private static PortableProfileDocument Document() => PortableProfileDocument.FromProfile(new ConnectionProfile
    {
        Id = Guid.NewGuid(), Name = "Native filesystem fixture", SsoStartUrl = "https://d-0000000000.awsapps.com/start",
        SsoRegion = "eu-west-1", AccountId = "000000000000", RoleName = "ExampleWorkstationRole",
        ResourceRegion = "eu-central-1", InstanceTagKey = "Name", InstanceTagValue = "example-workstation",
        LocalPort = 8443, RemotePort = 8443, ConnectAction = ConnectAction.TunnelOnly,
    });

    [NativeWindowsFact]
    public void Cfg04NewExportsHaveCurrentUserOnlyProtectedAcl()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        string path = PathFor("private.yaml");
        files.Save(Document(), path, null);
        ProfileFileSnapshot snapshot = files.Read(path);
        Assert.True(snapshot.CanWrite);
        FileSecurity security = new FileInfo(path).GetAccessControl();
        Assert.True(security.AreAccessRulesProtected);
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        Assert.Equal(identity.User, security.GetOwner(typeof(SecurityIdentifier)));
        Assert.All(security.GetAccessRules(true, true, typeof(SecurityIdentifier)).Cast<FileSystemAccessRule>(),
            rule => Assert.Equal(identity.User, rule.IdentityReference));
    }

    [NativeWindowsFact]
    public void Cfg04CheckedSavePreservesExistingDaclAndPortableIdentity()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        string path = PathFor("profile.json");
        PortableProfileDocument document = Document();
        files.Save(document, path, null);
        FileSecurity security = new FileInfo(path).GetAccessControl();
        security.AddAccessRule(new FileSystemAccessRule(new SecurityIdentifier(WellKnownSidType.AuthenticatedUserSid, null),
            FileSystemRights.Read, AccessControlType.Allow));
        new FileInfo(path).SetAccessControl(security);
        string before = new FileInfo(path).GetAccessControl()
            .GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group);
        ProfileFileSnapshot loaded = files.Read(path);
        files.Save(loaded.Document.WithProfile(loaded.Document.ToProfile() with { Name = "Changed" }), path, loaded.Revision);
        Assert.Equal(before, new FileInfo(path).GetAccessControl()
            .GetSecurityDescriptorSddlForm(AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group));
        Assert.Equal(document.Id, files.Read(path).Document.Id);
        Assert.Equal("Changed", files.Read(path).Document.Name);
    }

    [NativeWindowsFact]
    public void Cfg07StaleRevisionNeverOverwritesExternalBytes()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        string path = PathFor("race.yaml");
        files.Save(Document(), path, null);
        ProfileFileSnapshot loaded = files.Read(path);
        files.Save(loaded.Document.WithProfile(loaded.Document.ToProfile() with { Name = "External" }), path, loaded.Revision);
        byte[] external = File.ReadAllBytes(path);
        Assert.Throws<ProfileFileConflictException>(() => files.Save(loaded.Document, path, loaded.Revision));
        Assert.Equal(external, File.ReadAllBytes(path));
    }

    [NativeWindowsFact]
    public void Cfg06ReadOnlyAndInvalidUtf8AreExplicit()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        string path = PathFor("read-only.yaml");
        files.Save(Document(), path, null);
        File.SetAttributes(path, FileAttributes.ReadOnly);
        try
        {
            ProfileFileSnapshot readOnly = files.Read(path);
            Assert.False(readOnly.CanWrite);
            Assert.Throws<ProfilePortabilityException>(() => files.Save(readOnly.Document, path, readOnly.Revision));
        }
        finally { File.SetAttributes(path, FileAttributes.Normal); }
        File.WriteAllBytes(path, [0xff, 0xfe]);
        Assert.Throws<ProfilePortabilityException>(() => files.Read(path));
    }

    [NativeWindowsFact]
    public void Cfg07NewExportDoesNotOverwriteAnExistingDestination()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        string path = PathFor("existing.yaml");
        files.Save(Document(), path, null);
        byte[] before = File.ReadAllBytes(path);
        Assert.Throws<ProfileFileConflictException>(() => files.Save(Document(), path, null));
        Assert.Equal(before, File.ReadAllBytes(path));
    }

    [NativeWindowsFact]
    public void Cfg09AlternateStreamsAndAmbiguousSourceAliasesAreRefused()
    {
        Directory.CreateDirectory(_root);
        var files = new ProfileFiles();
        foreach (string name in new[] { "profile:stream.yaml", "profile.yaml.", "profile.yaml " })
        {
            Assert.Throws<ProfilePortabilityException>(() => files.Save(Document(), PathFor(name), null));
        }
        Assert.Empty(Directory.GetFiles(_root));
    }

    public void Dispose()
    {
        if (Directory.Exists(_root)) { Directory.Delete(_root, recursive: true); }
    }
}
