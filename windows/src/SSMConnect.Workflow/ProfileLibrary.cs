using SSMConnect.Domain;

namespace SSMConnect.Workflow;

public sealed record ProfileFileRevision(string Digest, string Identity, string Security, long Length, long LastWriteTicks);
public sealed record ProfileFileSnapshot(string Path, PortableProfileDocument Document, ProfileFileRevision Revision, bool CanWrite);
public sealed record ProfileAttachment(string Path, ProfileFileRevision Revision, bool CanonicalSaveAccepted = false);

public interface IProfileFiles
{
    ProfileFileSnapshot Read(string path);
    ProfileFileRevision? ExistingRevision(string path);
    ProfileFileRevision Save(PortableProfileDocument document, string path, ProfileFileRevision? expected);
}

public sealed class ProfileFileConflictException() : ProfilePortabilityException(
    "The profile file changed since it was loaded. Reload and review the changes, or save a local copy. Nothing was overwritten.");

public sealed class ProfileLibrary
{
    private readonly IProfileFiles _files;
    private readonly IReadOnlySet<string> _supported;
    private readonly Dictionary<Guid, PortableProfileDocument> _documents;
    private readonly Dictionary<Guid, ProfileAttachment> _attachments;
    private readonly Dictionary<Guid, ProfileFileSnapshot> _pending = [];
    private readonly Dictionary<Guid, string> _errors = [];

    public ProfileLibrary(IEnumerable<ConnectionProfile> profiles, IProfileFiles files, IReadOnlySet<string> supported,
        IReadOnlyDictionary<Guid, PortableProfileDocument>? documents = null,
        IReadOnlyDictionary<Guid, ProfileAttachment>? attachments = null)
    {
        Profiles = [.. profiles];
        _files = files;
        _supported = supported;
        _documents = documents?.ToDictionary() ?? [];
        _attachments = attachments?.ToDictionary() ?? [];
        foreach ((Guid id, PortableProfileDocument document) in _documents)
        {
            _ = ProfilePortability.Import(ProfilePortability.Export(document));
            if (!Profiles.Any(profile => profile.Id == id))
            {
                throw new ProfilePortabilityException("Saved portable document metadata refers to a missing local profile.");
            }
        }
        if (_attachments.Any(pair => !_documents.ContainsKey(pair.Key)))
        {
            throw new ProfilePortabilityException("Saved attachments are missing their portable document metadata. Existing profile files were not changed.");
        }
    }

    public List<ConnectionProfile> Profiles { get; }
    public IReadOnlyDictionary<Guid, PortableProfileDocument> Documents => _documents;
    public IReadOnlyDictionary<Guid, ProfileAttachment> Attachments => _attachments;
    public IReadOnlyDictionary<Guid, ProfileFileSnapshot> Pending => _pending;
    public IReadOnlyDictionary<Guid, string> Errors => _errors;

    public ConnectionProfile Import(ProfileFileSnapshot preview, bool attach)
    {
        ProfileFileSnapshot current = _files.Read(preview.Path);
        if (current.Revision != preview.Revision) { throw new ProfileFileConflictException(); }
        current.Document.EnsureSupported(_supported);
        if (attach && _attachments.Values.Any(value => SamePath(value.Path, current.Path)))
        {
            throw new ProfilePortabilityException("This file is already attached. Select its existing local profile.");
        }
        ConnectionProfile profile = current.Document.ToProfile() with { Id = Guid.NewGuid() };
        _documents[profile.Id] = current.Document;
        if (attach) { _attachments[profile.Id] = new ProfileAttachment(current.Path, current.Revision); }
        Profiles.Add(profile);
        return profile;
    }

    public void SaveProfile(ConnectionProfile profile, ProfileFileRevision? expected, bool acceptCanonicalFormatting)
    {
        int index = Index(profile.Id);
        if (_attachments.TryGetValue(profile.Id, out ProfileAttachment? attachment))
        {
            if (expected is null || expected != attachment.Revision) { throw new ProfileFileConflictException(); }
            if (!attachment.CanonicalSaveAccepted && !acceptCanonicalFormatting)
            {
                throw new ProfilePortabilityException(
                    "Saving an attached file uses canonical formatting and may remove YAML comments. Confirm this policy or save a local copy.");
            }
            PortableProfileDocument document = _documents[profile.Id].WithProfile(profile);
            document.EnsureSupported(_supported);
            ProfileFileRevision revision = _files.Save(document, attachment.Path, expected);
            _documents[profile.Id] = document;
            _attachments[profile.Id] = attachment with { Revision = revision, CanonicalSaveAccepted = true };
            _pending.Remove(profile.Id);
            _errors.Remove(profile.Id);
        }
        Profiles[index] = profile;
    }

    public PortableProfileDocument Export(Guid id)
    {
        ConnectionProfile profile = Profiles[Index(id)];
        PortableProfileDocument document = _documents.TryGetValue(id, out PortableProfileDocument? old)
            ? old.WithProfile(profile) : PortableProfileDocument.FromProfile(profile, documentId: Guid.NewGuid());
        _ = ProfilePortability.Export(document);
        _documents[id] = document;
        return document;
    }

    public ConnectionProfile SaveLocalCopy(ConnectionProfile draft, Guid originalId)
    {
        ConnectionProfile copy = draft with { Id = Guid.NewGuid(), Name = draft.Name + " Copy" };
        if (_documents.TryGetValue(originalId, out PortableProfileDocument? document))
        {
            _documents[copy.Id] = document.WithProfile(copy) with { Id = Guid.NewGuid() };
        }
        Profiles.Add(copy);
        return copy;
    }

    public void Refresh()
    {
        foreach ((Guid id, ProfileAttachment attachment) in _attachments)
        {
            try
            {
                ProfileFileSnapshot snapshot = _files.Read(attachment.Path);
                if (snapshot.Document.Id != _documents[id].Id)
                {
                    throw new ProfilePortabilityException("The file's document identity changed. Attach it as a new profile instead.");
                }
                snapshot.Document.EnsureSupported(_supported);
                _errors.Remove(id);
                if (snapshot.Revision != attachment.Revision) { _pending[id] = snapshot; }
                else { _pending.Remove(id); }
            }
            catch (Exception error) when (error is ProfilePortabilityException or IOException or UnauthorizedAccessException)
            {
                _pending.Remove(id);
                _errors[id] = error.Message + " Existing configuration and access were retained. Locate the file, detach it, or save a local copy.";
            }
        }
    }

    public void Apply(Guid id)
    {
        if (!_pending.TryGetValue(id, out ProfileFileSnapshot? pending))
        {
            throw new ProfilePortabilityException("There are no validated external changes to apply.");
        }
        ProfileAttachment attachment = _attachments[id];
        ProfileFileSnapshot current = _files.Read(attachment.Path);
        if (current.Revision != pending.Revision) { throw new ProfileFileConflictException(); }
        current.Document.EnsureSupported(_supported);
        Profiles[Index(id)] = current.Document.ToProfile() with { Id = id };
        _documents[id] = current.Document;
        _attachments[id] = attachment with { Revision = current.Revision };
        _pending.Remove(id);
        _errors.Remove(id);
    }

    public void Locate(Guid id, string path)
    {
        if (!_attachments.TryGetValue(id, out ProfileAttachment? attachment))
        {
            throw new ProfilePortabilityException("Select an attached profile first.");
        }
        ProfileFileSnapshot snapshot = _files.Read(path);
        if (snapshot.Document.Id != _documents[id].Id)
        {
            throw new ProfilePortabilityException("This is a different document. Attach it as a new profile instead.");
        }
        snapshot.Document.EnsureSupported(_supported);
        if (_attachments.Any(pair => pair.Key != id && SamePath(pair.Value.Path, snapshot.Path)))
        {
            throw new ProfilePortabilityException("That file is already attached to another local profile.");
        }
        _attachments[id] = attachment with { Path = snapshot.Path };
        _pending[id] = snapshot;
        _errors.Remove(id);
    }

    public void Detach(Guid id) { _attachments.Remove(id); _pending.Remove(id); _errors.Remove(id); }
    public void Remove(Guid id) { Profiles.RemoveAt(Index(id)); Detach(id); _documents.Remove(id); }

    private int Index(Guid id)
    {
        int index = Profiles.FindIndex(profile => profile.Id == id);
        return index >= 0 ? index : throw new ProfilePortabilityException("The selected local profile no longer exists.");
    }

    private static bool SamePath(string left, string right) => string.Equals(left, right, StringComparison.OrdinalIgnoreCase);
}
