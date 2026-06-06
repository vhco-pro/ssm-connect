import SwiftUI

/// App settings window (G6, F-18, ADR-3/ADR-5). Two tabs: **General** (login item + global
/// toggles) and **Profiles** (multi-profile management, collapses gracefully to one profile).
struct SettingsView: View {
    @Bindable var store: ProfileStore
    let loginItem: LoginItemControlling

    var body: some View {
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
    }

    private func startAdd() {
        isAdding = true
        editingProfile = ConnectionProfile.template
    }

    /// Open the editor pre-filled from a `~/.aws/config` entry so the user adds the tag + secret.
    private func startImport(_ profile: ConnectionProfile) {
        isAdding = true
        editingProfile = profile
    }
}
