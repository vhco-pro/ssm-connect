import AppKit
import SwiftUI
import UniformTypeIdentifiers
import SSMConnectDomain
import SSMConnectWorkflow
import SSMConnectMacOS

/// App settings window (G6, F-18, ADR-3/ADR-5). Two tabs: **General** (login item + global
/// toggles) and **Profiles** (multi-profile management, collapses gracefully to one profile).
public struct SettingsView: View {
    @Bindable public var store: ProfileStore
    public let loginItem: LoginItemControlling

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
    @Bindable public var store: ProfileStore
    public let loginItem: LoginItemControlling

    @State private var launchAtLogin = false
    @State private var loginItemError: String?

    public var body: some View {
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
    @Bindable public var store: ProfileStore
    @State private var selection: UUID?
    @State private var editingProfile: ConnectionProfile?
    @State private var isAdding = false
    @State private var importable: [ConnectionProfile] = []
    /// Message from a failed portable-document import or export.
    @State private var portableError: String?

    public var body: some View {
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
                        if profile.id != store.activeProfileID {
                            Button("Use") { store.setActiveProfile(profile.id) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .tag(profile.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { editingProfile = profile }
                }
            }

            Divider()

            HStack {
                Button { startAdd() } label: { Image(systemName: "plus") }
                    .help("Add a blank profile")
                Menu {
                    // The portable document (spec §6.1) — the format the Windows client reads.
                    Button("From a profile file…") { importPortableProfile() }
                    Divider()
                    Section("From ~/.aws/config") {
                        if importable.isEmpty {
                            Text("No SSO profiles found")
                        } else {
                            ForEach(importable) { profile in
                                Button(profile.name) { startImport(profile) }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .help("Import a profile from a file or from ~/.aws/config")
                .menuIndicator(.hidden)
                .frame(width: 44)
                Button { exportPortableProfile() } label: { Image(systemName: "square.and.arrow.up") }
                    .help("Export the selected profile as a portable profile file")
                    .disabled(selection == nil)
                Button { if let id = selection { store.duplicateProfile(id) } } label: { Image(systemName: "doc.on.doc") }
                    .help("Duplicate the selected profile")
                    .disabled(selection == nil)
                Button { if let id = selection { store.deleteProfile(id) } } label: { Image(systemName: "minus") }
                    .help("Delete the selected profile")
                    .disabled(selection == nil || store.profiles.count <= 1)
                Spacer()
                Button("Edit…") { if let id = selection, let p = store.profiles.first(where: { $0.id == id }) { editingProfile = p } }
                    .disabled(selection == nil)
            }
            .buttonStyle(.bordered)
            .padding(8)
        }
        .sheet(item: $editingProfile) { profile in
            ProfileEditorView(profile: profile) { edited in
                if isAdding {
                    store.addProfile(edited)
                    isAdding = false
                } else {
                    store.updateProfile(edited)
                }
            }
        }
        .onAppear { importable = store.importableProfiles() }
        .alert(
            "Couldn't import that profile",
            isPresented: Binding(get: { portableError != nil }, set: { if !$0 { portableError = nil } })
        ) {
            Button("OK", role: .cancel) { portableError = nil }
        } message: {
            // ProfilePortabilityError names the offending field and value; showing anything less
            // would leave the user with a file that "doesn't work" and no way to find out why.
            Text(portableError ?? "")
        }
    }

    private func startAdd() {
        isAdding = true
        editingProfile = ConnectionProfile.template
    }

    // MARK: Portable profile documents (spec §6.1, AC-03)

    /// Write the selected profile as a portable document — the same format the Windows client reads.
    private func exportPortableProfile() {
        guard let id = selection, let profile = store.profiles.first(where: { $0.id == id }) else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(Self.fileNameSlug(profile.name)).ssm-profile.json"
        panel.message = "Export “\(profile.name)” as a portable connection profile."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ProfilePortability.export(profile).write(to: url)
        } catch {
            portableError = error.localizedDescription
        }
    }

    /// Read a portable document and open it in the editor rather than saving it straight away, so
    /// an imported profile gets the same confirmation step as one typed by hand.
    private func importPortableProfile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a connection profile file to import."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let imported = try ProfilePortability.importProfile(from: Data(contentsOf: url))
            // A fresh identity: importing the same document twice should give two profiles rather
            // than silently overwriting, and the stored ID is only meaningful within one client.
            var copy = imported
            copy.id = UUID()
            isAdding = true
            editingProfile = copy
        } catch {
            portableError = error.localizedDescription
        }
    }

    /// A filesystem-safe stem for the suggested export filename.
    private static func fileNameSlug(_ name: String) -> String {
        let allowed = name.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let slug = String(allowed).lowercased()
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return slug.isEmpty ? "connection-profile" : slug
    }

    /// Open the editor pre-filled from a `~/.aws/config` entry so the user adds the tag + secret.
    private func startImport(_ profile: ConnectionProfile) {
        isAdding = true
        editingProfile = profile
    }
}
