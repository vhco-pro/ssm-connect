import SwiftUI
import UniformTypeIdentifiers

/// App settings window (G6, F-18, ADR-3/ADR-5). Two tabs: **General** (login item + global
/// toggles) and **Profiles** (multi-profile management, collapses gracefully to one profile).
public struct SettingsView: View {
    @Bindable var store: ProfileStore
    let loginItem: LoginItemControlling

    public init(store: ProfileStore, loginItem: LoginItemControlling) {
        self.store = store
        self.loginItem = loginItem
    }

    public var body: some View {
        TabView {
            GeneralSettingsTab(store: store, loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }

            ProfilesSettingsTab(store: store)
                .tabItem { Label("Profiles", systemImage: "person.crop.rectangle.stack") }
        }
        .frame(width: 480, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var store: ProfileStore
    let loginItem: LoginItemControlling

    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLoginItem(newValue)
                    }
                Toggle("Connect automatically on launch", isOn: $store.settings.autoConnect)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Connection") {
                Toggle("Reconnect automatically if the tunnel drops", isOn: $store.settings.autoReconnect)
            }

            Section("Clipboard") {
                Stepper(
                    "Clear copied password after \(store.settings.clipboardAutoClearSeconds)s",
                    value: $store.settings.clipboardAutoClearSeconds,
                    in: 0...300,
                    step: 5
                )
                Text("Set to 0 to keep the password on the clipboard until you replace it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = loginItem.isEnabled }
    }

    private func setLoginItem(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = "Could not update the login item: \(error.localizedDescription)"
            // Re-sync the toggle with the real state.
            launchAtLogin = loginItem.isEnabled
        }
    }
}

// MARK: - Profiles

private struct ProfilesSettingsTab: View {
    @Bindable var store: ProfileStore
    @State private var selection: UUID?
    @State private var editingProfile: ConnectionProfile?
    @State private var isAdding = false
    @State private var importable: [ConnectionProfile] = []
    @State private var editingRevision: ProfileFileRevision?
    @State private var editingFileWritable = true
    @State private var fileError: String?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(store.profiles) { profile in
                    HStack {
                        Image(systemName: profile.id == store.activeProfileID ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(profile.id == store.activeProfileID ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(profile.name).fontWeight(.medium)
                            Text("\(profile.accountId) · \(profile.resourceRegion)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if store.attachments[profile.id] != nil {
                            Image(systemName: "doc.badge.gearshape").help("Attached to a profile file")
                        }
                        if profile.id != store.activeProfileID {
                            Button("Use") { store.setActiveProfile(profile.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .tag(profile.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { startEdit(profile) }
                }
            }

            if let selection {
                if let attachment = store.attachments[selection] {
                    Text(attachment.url.path).font(.caption).textSelection(.enabled).padding(.horizontal, 8)
                }
                if store.pendingFiles[selection] != nil {
                    Text("External changes pending. Review and Apply before using the new configuration.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                }
                if let error = store.fileErrors[selection] {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
                }
            }
            if let error = fileError ?? store.operationError {
                Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 8)
            }

            Divider()

            HStack {
                Button { startAdd() } label: { Image(systemName: "plus") }
                    .help("Add a blank profile")
                Menu {
                    if importable.isEmpty {
                        Text("No SSO profiles found in ~/.aws/config")
                    } else {
                        ForEach(importable) { profile in
                            Button(profile.name) { startImport(profile) }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import a profile from ~/.aws/config")
                .menuIndicator(.hidden)
                .frame(width: 44)
                Button { if let id = selection { store.duplicateProfile(id) } } label: { Image(systemName: "doc.on.doc") }
                    .help("Duplicate the selected profile")
                    .disabled(selection == nil)
                Button { if let id = selection { store.deleteProfile(id) } } label: { Image(systemName: "minus") }
                    .help("Delete the selected profile")
                    .disabled(selection == nil || store.profiles.count <= 1)
                Spacer()
                Menu("Files") {
                    Button("Open Profile File…") { fileOperation { try openProfileFile() } }
                    Button("Export Profile…") { fileOperation { try exportProfile() } }.disabled(selection == nil)
                    Button("Save a Local Copy") {
                        fileOperation {
                            guard let profile = selectedProfile else { return }
                            selection = try store.saveLocalCopy(profile, preservingFrom: profile.id).id
                        }
                    }.disabled(selection == nil)
                    if let selection, store.attachments[selection] != nil {
                        Divider()
                        Button("Reload / Review Changes") {
                            store.refreshAttachedFiles()
                            fileOperation { try reviewPendingFile(selection) }
                        }
                        Button("Apply External Changes") { fileOperation { try applyPendingFile(selection) } }
                            .disabled(store.pendingFiles[selection] == nil)
                        Button("Locate File…") {
                            fileOperation {
                                if let url = chooseProfileFile() { try store.locateFile(selection, at: url) }
                            }
                        }
                        Button("Detach (Keep Local Profile)") { store.detachFile(selection) }
                    }
                }
                Button("Edit…") { if let profile = selectedProfile { startEdit(profile) } }
                    .disabled(selection == nil)
            }
            .buttonStyle(.bordered)
            .padding(8)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(profile: profile, attachedFile: store.attachments[profile.id]?.url,
                              attachedFileIsWritable: editingFileWritable,
                              onSaveCopy: store.attachments[profile.id] == nil ? nil : { edited in
                                  selection = try store.saveLocalCopy(edited, preservingFrom: profile.id).id
                              }) { edited in
                if isAdding {
                    store.addProfile(edited)
                    isAdding = false
                } else {
                    let accepted = store.attachments[profile.id]?.canonicalSaveAccepted == true
                    if store.attachments[profile.id] != nil, !accepted {
                        guard confirm("Save canonical profile formatting?",
                            "This writes the attached file and may normalize layout or remove YAML comments. Legacy v1 files upgrade to schema v2; older clients may not read them. Validated values and permitted optional fields are preserved. Choose Cancel to keep editing or save a local copy.") else {
                            throw PortableProfileError.formattingConsentRequired
                        }
                    }
                    try store.saveEditedProfile(edited, expected: editingRevision, acceptCanonicalFormatting: true)
                }
            }
        }
        .onAppear {
            importable = store.importableProfiles()
            if selection == nil { selection = store.activeProfileID }
            store.refreshAttachedFiles()
        }
    }

    private func startAdd() {
        isAdding = true
        editingRevision = nil
        editingProfile = ConnectionProfile.template
    }

    /// Open the editor pre-filled from a `~/.aws/config` entry so the user adds the tag + secret.
    private func startImport(_ profile: ConnectionProfile) {
        isAdding = true
        editingRevision = nil
        editingProfile = profile
    }

    private var selectedProfile: ConnectionProfile? { store.profiles.first { $0.id == selection } }

    private func startEdit(_ profile: ConnectionProfile) {
        isAdding = false
        editingRevision = store.attachments[profile.id]?.revision
        editingFileWritable = true
        if let attachment = store.attachments[profile.id] {
            do { editingFileWritable = try ProfileFileIO.read(attachment.url).isWritable }
            catch { editingFileWritable = false; fileError = error.localizedDescription }
        }
        editingProfile = profile
    }

    private func chooseProfileFile() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["json", "yaml", "yml"].compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func openProfileFile() throws {
        guard let url = chooseProfileFile() else { return }
        let preview = try ProfileFileIO.read(url)
        let profile = try preview.document.profile(localID: UUID())
        let alert = NSAlert()
        alert.messageText = "Open \(profile.name)?"
        alert.informativeText = "Preview only: no AWS access, connection or integration setup has occurred.\n"
            + "Account: \(profile.accountId), role: \(profile.roleName)\n"
            + "Region: \(profile.resourceRegion), target: \(profile.instanceTagKey)=\(profile.instanceTagValue)\n"
            + (preview.isWritable ? "Attach to edit the same file, or import an independent local copy."
                : "This file is read-only. You can attach it for external updates or import a local copy.")
        try setPreview(preview.document, on: alert)
        alert.addButton(withTitle: "Attach File")
        alert.addButton(withTitle: "Import as Local Copy")
        alert.addButton(withTitle: "Cancel")
        let result = alert.runModal()
        guard result != .alertThirdButtonReturn else { return }
        selection = try store.importFile(preview, attach: result == .alertFirstButtonReturn).id
    }

    private func exportProfile() throws {
        guard let profile = selectedProfile else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "workstation.yaml"
        panel.allowedContentTypes = ["json", "yaml", "yml"].compactMap { UTType(filenameExtension: $0) }
        panel.message = "Export non-secret configuration as canonical YAML or JSON. Comments/layout may be normalized. Review infrastructure metadata before sharing."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = try ProfileFileIO.save(store.exportDocument(profile.id), to: url, expected: ProfileFileIO.existingRevision(url))
    }

    private func reviewPendingFile(_ id: UUID) throws {
        guard let pending = store.pendingFiles[id] else { return }
        let alert = NSAlert()
        alert.messageText = "Review external profile changes"
        alert.informativeText = "The stored configuration and existing connections have not changed. Apply replaces the stored configuration only; existing transport-specific pending-Apply and ownership checks still apply."
        try setPreview(pending.document, on: alert)
        alert.addButton(withTitle: "Keep Pending")
        alert.runModal()
    }

    private func applyPendingFile(_ id: UUID) throws {
        guard confirm("Apply external profile changes?",
            "Use the validated file values for future operations. Existing connections are not redirected or reconnected. Web routing changes still require their separate Apply action.") else { return }
        try store.applyPendingFile(id)
    }

    private func setPreview(_ document: PortableProfileDocument, on alert: NSAlert) throws {
        let data = try ProfileDocumentCodec.write(document, format: .json)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 220))
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        text.string = String(decoding: data, as: UTF8.self)
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        alert.accessoryView = scroll
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func fileOperation(_ operation: () throws -> Void) {
        do { try operation(); fileError = nil }
        catch { fileError = error.localizedDescription }
    }
}
