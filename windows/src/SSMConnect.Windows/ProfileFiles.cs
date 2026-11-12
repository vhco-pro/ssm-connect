using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using Microsoft.Win32.SafeHandles;
using SSMConnect.Domain;
using SSMConnect.Workflow;

namespace SSMConnect.Windows;

[SupportedOSPlatform("windows")]
public sealed partial class ProfileFiles : IProfileFiles
{
    private const uint ReadAccess = 0x80000000;
    private const uint WriteAccess = 0x40000000;
    private const uint ReadWriteDeleteSharing = 1 | 2 | 4;
    private const uint ReparsePoint = 0x400;
    private const uint DirectoryAttribute = 0x10;
    private const uint ReadOnlyAttribute = 1;
    private static readonly UTF8Encoding Utf8 = new(false, true);

    public ProfileFileSnapshot Read(string path)
    {
        path = LocalPath(path);
        RawProfile raw = ReadRaw(path);
        string text;
        try { text = Utf8.GetString(raw.Data); }
        catch (DecoderFallbackException) { throw new ProfilePortabilityException("Profile files must use valid UTF-8."); }
        PortableProfileDocument document = ProfilePortability.Import(text, ProfileDocumentSyntax.FormatForPath(path));
        return new ProfileFileSnapshot(path, document, raw.Revision, raw.CanWrite);
    }

    public ProfileFileRevision? ExistingRevision(string path)
    {
        try { return ReadRaw(LocalPath(path)).Revision; }
        catch (FileNotFoundException) { return null; }
    }

    public ProfileFileRevision Save(PortableProfileDocument document, string path, ProfileFileRevision? expected)
    {
        path = LocalPath(path);
        byte[] bytes = Utf8.GetBytes(ProfilePortability.Export(document, ProfileDocumentSyntax.FormatForPath(path)));
        string directory = Path.GetDirectoryName(path)!;
        using var mutex = new Mutex(false, @"Local\SSMConnect.Profile." + Digest(Utf8.GetBytes(path.ToUpperInvariant())));
        bool locked;
        try { locked = mutex.WaitOne(TimeSpan.FromSeconds(10)); }
        catch (AbandonedMutexException) { locked = true; }
        if (!locked) { throw new IOException("Another SSM Connect process is saving this profile. Retry after it finishes."); }
        string? temporary = null;
        try
        {
            CheckAncestors(directory);
            using SafeFileHandle parent = Native.CreateFile(directory, ReadAccess, 1 | 2, IntPtr.Zero, 3,
                0x02000000 | 0x00200000, IntPtr.Zero);
            RequireHandle(parent);
            FileSecurity? originalSecurity = null;
            if (expected is not null)
            {
                RawProfile current = ReadRaw(path);
                if (current.Revision != expected) { throw new ProfileFileConflictException(); }
                if (!current.CanWrite)
                {
                    throw new ProfilePortabilityException("This profile file is read-only, locked or owned by another user. Save a local copy.");
                }
                originalSecurity = current.Security;
            }
            else if (ExistingRevision(path) is not null) { throw new ProfileFileConflictException(); }

            temporary = Path.Combine(directory, ".ssm-profile-" + Guid.NewGuid().ToString("N"));
            using (FileStream writer = new FileInfo(temporary).Create(FileMode.CreateNew,
                       FileSystemRights.FullControl, FileShare.None, 4096, FileOptions.WriteThrough, PrivateSecurity()))
            {
                if (originalSecurity is not null)
                {
                    var security = new FileSecurity();
                    security.SetSecurityDescriptorBinaryForm(originalSecurity.GetSecurityDescriptorBinaryForm(),
                        AccessControlSections.Access | AccessControlSections.Owner | AccessControlSections.Group);
                    writer.SetAccessControl(security);
                }
                writer.Write(bytes);
                writer.Flush(flushToDisk: true);
            }
            if (expected != ExistingRevision(path)) { throw new ProfileFileConflictException(); }
            // Rename replaces the directory entry itself, never writes through a destination link.
            File.Move(temporary, path, overwrite: expected is not null);
            temporary = null;
            RawProfile written = ReadRaw(path);
            if (written.Revision.Digest != Digest(bytes)) { throw new ProfileFileConflictException(); }
            return written.Revision;
        }
        finally
        {
            try
            {
                if (temporary is not null) { File.Delete(temporary); }
            }
            finally { mutex.ReleaseMutex(); }
        }
    }

    private static RawProfile ReadRaw(string path)
    {
        CheckAncestors(Path.GetDirectoryName(path)!);
        using SafeFileHandle handle = Native.CreateFile(path, ReadAccess, ReadWriteDeleteSharing,
            IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        RequireHandle(handle);
        ByHandleInformation before = Information(handle);
        if ((before.Attributes & (ReparsePoint | DirectoryAttribute)) != 0 || before.Links != 1)
        {
            throw new ProfilePortabilityException("Profiles must be regular local files, not symbolic links, reparse points or hard links.");
        }
        long length = ((long)before.SizeHigh << 32) | before.SizeLow;
        if (length > ProfileDocumentSyntax.MaximumBytes) { throw new ProfilePortabilityException("Profile files must be at most 256 KiB."); }
        using var stream = new FileStream(handle, FileAccess.Read);
        using var data = new MemoryStream();
        var buffer = new byte[16 * 1024];
        int count;
        while ((count = stream.Read(buffer)) > 0)
        {
            data.Write(buffer, 0, count);
            if (data.Length > ProfileDocumentSyntax.MaximumBytes)
            {
                throw new ProfilePortabilityException("Profile files must be at most 256 KiB.");
            }
        }
        ByHandleInformation after = Information(handle);
        if (before.SizeLow != after.SizeLow || before.SizeHigh != after.SizeHigh
            || before.WriteHigh != after.WriteHigh || before.WriteLow != after.WriteLow)
        {
            throw new ProfileFileConflictException();
        }
        FileSecurity security = stream.GetAccessControl();
        SecurityIdentifier user = CurrentUser();
        bool owned = security.GetOwner(typeof(SecurityIdentifier))?.Equals(user) == true;
        bool canWrite = owned && (before.Attributes & ReadOnlyAttribute) == 0 && CanOpenForWrite(path);
        byte[] bytes = data.ToArray();
        var revision = new ProfileFileRevision(Digest(bytes),
            $"{before.Volume}:{before.IndexHigh}:{before.IndexLow}",
            Digest(security.GetSecurityDescriptorBinaryForm()), bytes.LongLength,
            ((long)before.WriteHigh << 32) | before.WriteLow);
        return new RawProfile(bytes, revision, security, canWrite);
    }

    private static bool CanOpenForWrite(string path)
    {
        using SafeFileHandle handle = Native.CreateFile(path, WriteAccess, ReadWriteDeleteSharing,
            IntPtr.Zero, 3, 0x00200000, IntPtr.Zero);
        if (!handle.IsInvalid)
        {
            return (Information(handle).Attributes & (ReparsePoint | DirectoryAttribute)) == 0;
        }
        int error = Marshal.GetLastWin32Error();
        if (error is 5 or 32 or 33) { return false; }
        throw AccessError(error);
    }

    private static string LocalPath(string path)
    {
        string full = Path.GetFullPath(path);
        if (full.StartsWith(@"\\", StringComparison.Ordinal)
            || new DriveInfo(Path.GetPathRoot(full)!).DriveType == DriveType.Network)
        {
            throw new ProfilePortabilityException("Attached profile files currently require a local Windows filesystem, not a network or device path.");
        }
        string root = Path.GetPathRoot(full)!;
        if (full[root.Length..].Split(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)
            .Any(part => part.Contains(':') || part.EndsWith('.') || part.EndsWith(' ')))
        {
            throw new ProfilePortabilityException("Use a regular local file path, not an alternate data stream or ambiguous trailing-dot/space path.");
        }
        return full;
    }

    private static void CheckAncestors(string directory)
    {
        for (DirectoryInfo? current = new(directory); current is not null; current = current.Parent)
        {
            if ((current.Attributes & FileAttributes.ReparsePoint) != 0)
            {
                throw new ProfilePortabilityException("Profile paths through junctions or symbolic-link directories are not supported. Choose a regular local path.");
            }
        }
    }

    private static FileSecurity PrivateSecurity()
    {
        SecurityIdentifier user = CurrentUser();
        var security = new FileSecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(user);
        security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, AccessControlType.Allow));
        return security;
    }

    private static SecurityIdentifier CurrentUser()
    {
        using WindowsIdentity identity = WindowsIdentity.GetCurrent();
        return identity.User ?? throw new IOException("The current Windows identity has no user SID.");
    }

    private static string Digest(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
    private static void RequireHandle(SafeFileHandle handle)
    {
        if (!handle.IsInvalid) { return; }
        int error = Marshal.GetLastWin32Error();
        if (error is 2 or 3) { throw new FileNotFoundException("The selected profile file is missing."); }
        throw AccessError(error);
    }

    private static IOException AccessError(int error) => new("The profile filesystem operation failed.", new Win32Exception(error));
    private static ByHandleInformation Information(SafeFileHandle handle)
    {
        if (!Native.GetFileInformationByHandle(handle, out ByHandleInformation information))
        {
            throw AccessError(Marshal.GetLastWin32Error());
        }
        return information;
    }

    private sealed record RawProfile(byte[] Data, ProfileFileRevision Revision, FileSecurity Security, bool CanWrite);

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleInformation
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh;
        public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }

    private static partial class Native
    {
        [LibraryImport("kernel32.dll", EntryPoint = "CreateFileW", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
        internal static partial SafeFileHandle CreateFile(string path, uint access, uint sharing,
            IntPtr security, uint creation, uint flags, IntPtr template);

        [LibraryImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static partial bool GetFileInformationByHandle(SafeFileHandle handle, out ByHandleInformation information);
    }
}
