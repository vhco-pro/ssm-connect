import SwiftUI

/// Form editor for a single `ConnectionProfile` (G7, F-18). Validates required fields and
/// port ranges before allowing Save. Used for both add and edit (the caller decides which).
struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfile
    @State private var webConfiguration: WebForwardsConfiguration
    @State private var remoteConfiguration: RemoteDevelopmentConfiguration
    @State private var proxyDomains: [ProxyDomainDraft]
    private let onSave: (ConnectionProfile) -> Void

    private struct ProxyDomainDraft: Identifiable {
        let id = UUID()
        var suffix: String
    }

    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile) -> Void) {
        _draft = State(initialValue: profile)
        _webConfiguration = State(initialValue: profile.webForwards ?? .init())
        _remoteConfiguration = State(initialValue: profile.remoteDevelopment ?? .init())
        _proxyDomains = State(initialValue: (profile.webForwards?.proxySuffixes ?? [])
            .map { ProxyDomainDraft(suffix: $0) })
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    TextField("Display name", text: $draft.name)
                }

                Section("AWS SSO") {
                    TextField("SSO start URL", text: $draft.ssoStartUrl)
                    TextField("SSO region", text: $draft.ssoRegion)
                    regionError(for: draft.ssoRegion)
                    TextField("Account ID", text: $draft.accountId)
                    TextField("Role name", text: $draft.roleName)
                }

                Section("Workstation") {
                    TextField("Resource region", text: $draft.resourceRegion)
                    regionError(for: draft.resourceRegion)
                    TextField("Instance tag key", text: $draft.instanceTagKey)
                    TextField("Instance tag value", text: $draft.instanceTagValue)
                    TextField("DCV password secret id (optional)", text: secretIdBinding)
                }

                Section("Tunnel") {
                    portField("Local port", value: $draft.localPort)
                    portField("Remote port", value: $draft.remotePort)
                    Toggle("Open DCV Viewer automatically", isOn: automaticDCVBinding)
                }

                Section("Connect mode") {
                    Picker("Mode", selection: connectModeBinding) {
                        ForEach(ConnectMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    if draft.resolvedConnectMode == .multiUser {
                        portField("Agent port", value: agentPortBinding)
                        Text("You log in with your own AWS SSO identity into your own desktop. "
                            + "Requires a workstation deployed in multi-user mode (on-box agent + virtual sessions). "
                            + "No password is used.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Vanilla ec2-user + Secrets-Manager password — the default. "
                            + "Works against a standard single-user workstation.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Remote Development") {
                    Toggle("Enable native VS Code access", isOn: $remoteConfiguration.enabled)
                    if remoteConfiguration.enabled {
                        TextField("Remote folder (optional)", text: remoteFolderBinding,
                                  prompt: Text("/home/user/code/project"))
                        LabeledContent("Editor", value: "Visual Studio Code / Remote - SSH")
                        if let folder = remoteConfiguration.folder, !folder.isEmpty,
                           (try? RemoteSSHConfiguration.folderURI(alias: RemoteSSHConfiguration.alias(draft.id), folder: folder)) == nil {
                            Text("Use an absolute remote folder path.").font(.caption).foregroundStyle(.red)
                        }
                    }
                }

                Section("Web Forwards") {
                    Toggle("Enable web forwards", isOn: $webConfiguration.enabled)
                    if webConfiguration.enabled {
                        TextField("SSH user (optional)", text: sshUserBinding)
                        Toggle("SOCKS proxy", isOn: socksEnabledBinding)
                        if webConfiguration.socksPort != nil {
                            portField("SOCKS port", value: socksPortBinding)
                            Picker("Browser", selection: browserBinding) {
                                Text("Automatic").tag(ManagedBrowserChoice.automatic)
                                if let selected = webConfiguration.browser, selected != .automatic,
                                   !BrowserDescriptor.installed().contains(where: {
                                       $0.choice == selected && $0.supports(webConfiguration.browserMode ?? .separate)
                                   }) {
                                    Text("\(selected.name) (unavailable)").tag(selected).disabled(true)
                                }
                                ForEach(BrowserDescriptor.installed().filter {
                                    $0.supports(webConfiguration.browserMode ?? .separate)
                                }, id: \.choice) { browser in
                                    Text(browser.choice.name).tag(browser.choice)
                                }
                            }
                            Picker("Browser Mode", selection: $webConfiguration.browserMode) {
                                Text("Choose").tag(BrowserMode?.none)
                                ForEach(BrowserMode.allCases) { mode in
                                    Text(mode.name).tag(Optional(mode))
                                }
                            }
                            .pickerStyle(.segmented)
                            if webConfiguration.browserMode == .existing {
                                LabeledContent("Profile", value: webConfiguration.browserProfilePath
                                    .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Not selected")
                                Button { chooseBrowserProfile() } label: {
                                    Label("Choose Profile Folder", systemImage: "folder")
                                }
                                Text("Zen only. Chrome requires a separately approved proxy extension and is unavailable in this mode.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach($proxyDomains) { $domain in
                                HStack {
                                    TextField("Domain suffix", text: $domain.suffix,
                                              prompt: Text(".internal.example.com"))
                                    Button {
                                        proxyDomains.removeAll { $0.id == domain.id }
                                    } label: { Image(systemName: "minus.circle") }
                                    .help("Remove domain")
                                    .accessibilityLabel("Remove domain")
                                }
                            }
                            Button {
                                proxyDomains.append(ProxyDomainDraft(suffix: ""))
                            } label: { Label("Add Domain", systemImage: "plus") }
                            .help("Add a proxy domain suffix")
                            .accessibilityLabel("Add Domain")
                        }
                        ForEach(webConfiguration.localForwards.indices, id: \.self) { index in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("Name", text: $webConfiguration.localForwards[index].name)
                                    Button {
                                        webConfiguration.localForwards.remove(at: index)
                                    } label: { Image(systemName: "minus.circle") }
                                    .help("Remove local forward")
                                }
                                portField("Local port", value: $webConfiguration.localForwards[index].localPort)
                                TextField("Remote host", text: $webConfiguration.localForwards[index].remoteHost)
                                portField("Remote port", value: $webConfiguration.localForwards[index].remotePort)
                                TextField("Open path (optional)", text: openPathBinding(index))
                            }
                        }
                        Button {
                            webConfiguration.localForwards.append(.init(name: "New Forward", localPort: 8080,
                                remoteHost: "127.0.0.1", remotePort: 8080))
                        } label: { Label("Add Local Forward", systemImage: "plus") }
                        if let error = webValidationError {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    // Trim region fields on commit so stored profiles are clean.
                    draft.resourceRegion = AWSRegion.normalize(draft.resourceRegion)
                    draft.ssoRegion = AWSRegion.normalize(draft.ssoRegion)
                    draft.webForwards = webConfiguration.enabled || draft.webForwards != nil
                        ? normalizedWebConfiguration : nil
                    draft.remoteDevelopment = remoteConfiguration.enabled || draft.remoteDevelopment != nil
                        ? remoteConfiguration : nil
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 460, height: 640)
    }

    // MARK: Validation

    private var isValid: Bool {
        !trimmed(draft.name).isEmpty
            && !trimmed(draft.ssoStartUrl).isEmpty
            && ProfileEditorValidation.regionState(draft.ssoRegion).isValid
            && !trimmed(draft.accountId).isEmpty
            && !trimmed(draft.roleName).isEmpty
            && ProfileEditorValidation.regionState(draft.resourceRegion).isValid
            && !trimmed(draft.instanceTagKey).isEmpty
            && !trimmed(draft.instanceTagValue).isEmpty
            && (1...65535).contains(draft.localPort)
            && (1...65535).contains(draft.remotePort)
            && (!webConfiguration.enabled || webValidationError == nil)
            && (!remoteConfiguration.enabled || remoteConfiguration.folder == nil || remoteConfiguration.folder == ""
                || (try? RemoteSSHConfiguration.folderURI(alias: RemoteSSHConfiguration.alias(draft.id), folder: remoteConfiguration.folder!)) != nil)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedWebConfiguration: WebForwardsConfiguration {
        var configuration = webConfiguration
        configuration.sshUser = configuration.sshUser.map(trimmed)
        configuration.proxySuffixes = configuration.socksPort == nil ? []
            : ProfileEditorValidation.normalizedProxySuffixes(proxyDomains.map(\.suffix))
        return configuration
    }

    private var webValidationError: String? {
        ProfileEditorValidation.webForwardsError(normalizedWebConfiguration)
    }

    private var automaticDCVBinding: Binding<Bool> {
        Binding(get: { draft.connectAction == .dcvViewer }, set: { draft.connectAction = $0 ? .dcvViewer : .tunnelOnly })
    }

    private var sshUserBinding: Binding<String> {
        Binding(get: { webConfiguration.sshUser ?? "" }, set: { webConfiguration.sshUser = $0.isEmpty ? nil : $0 })
    }

    private var socksEnabledBinding: Binding<Bool> {
        Binding(get: { webConfiguration.socksPort != nil }, set: { webConfiguration.socksPort = $0 ? 1080 : nil })
    }

    private var socksPortBinding: Binding<Int> {
        Binding(get: { webConfiguration.socksPort ?? 1080 }, set: { webConfiguration.socksPort = $0 })
    }

    private var browserBinding: Binding<ManagedBrowserChoice> {
        Binding(get: { webConfiguration.browser ?? .automatic }, set: { webConfiguration.browser = $0 })
    }

    private var remoteFolderBinding: Binding<String> {
        Binding(get: { remoteConfiguration.folder ?? "" }, set: { remoteConfiguration.folder = $0.isEmpty ? nil : $0 })
    }

    private func chooseBrowserProfile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select your Zen profile folder containing prefs.js. No proxy settings change until setup is confirmed."
        if panel.runModal() == .OK { webConfiguration.browserProfilePath = panel.url?.path }
    }

    private func openPathBinding(_ index: Int) -> Binding<String> {
        Binding(get: { webConfiguration.localForwards[index].openPath ?? "" },
                set: { webConfiguration.localForwards[index].openPath = $0.isEmpty ? nil : $0 })
    }

    /// Inline field-level error shown only when a region field is non-empty but malformed, so a
    /// fresh empty form stays quiet while Save remains disabled until it is valid.
    @ViewBuilder
    private func regionError(for value: String) -> some View {
        if ProfileEditorValidation.regionState(value).showError {
            Text("Not a valid AWS region (e.g. eu-central-1).")
                .font(.caption).foregroundStyle(.red)
        }
    }

    /// Bridges the optional `secretId` to a non-optional text binding (empty == nil).
    private var secretIdBinding: Binding<String> {
        Binding(
            get: { draft.secretId ?? "" },
            set: { draft.secretId = $0.isEmpty ? nil : $0 }
        )
    }

    /// Bridges the optional `connectMode` to a non-optional picker selection (nil == singleUser).
    private var connectModeBinding: Binding<ConnectMode> {
        Binding(
            get: { draft.resolvedConnectMode },
            set: { draft.connectMode = $0 }
        )
    }

    /// Bridges the optional `agentRemotePort` to a non-optional port field (nil == 8444).
    private var agentPortBinding: Binding<Int> {
        Binding(
            get: { draft.resolvedAgentRemotePort },
            set: { draft.agentRemotePort = $0 }
        )
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
    }
}
