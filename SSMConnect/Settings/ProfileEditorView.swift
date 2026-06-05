import SwiftUI

/// Form editor for a single `ConnectionProfile` (G7, F-18). Validates required fields and
/// port ranges before allowing Save. Used for both add and edit (the caller decides which).
struct ProfileEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ConnectionProfile
    private let onSave: (ConnectionProfile) -> Void

    init(profile: ConnectionProfile, onSave: @escaping (ConnectionProfile) -> Void) {
        _draft = State(initialValue: profile)
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
                    TextField("Account ID", text: $draft.accountId)
                    TextField("Role name", text: $draft.roleName)
                }

                Section("Workstation") {
                    TextField("Resource region", text: $draft.resourceRegion)
                    TextField("Instance tag key", text: $draft.instanceTagKey)
                    TextField("Instance tag value", text: $draft.instanceTagValue)
                    TextField("DCV password secret id (optional)", text: secretIdBinding)
                }

                Section("Tunnel") {
                    portField("Local port", value: $draft.localPort)
                    portField("Remote port", value: $draft.remotePort)
                    LabeledContent("Connect action", value: draft.connectAction.displayName)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
            }
            .padding(12)
        }
        .frame(width: 460, height: 520)
    }

    // MARK: Validation

    private var isValid: Bool {
        !trimmed(draft.name).isEmpty
            && !trimmed(draft.ssoStartUrl).isEmpty
            && !trimmed(draft.ssoRegion).isEmpty
            && !trimmed(draft.accountId).isEmpty
            && !trimmed(draft.roleName).isEmpty
            && !trimmed(draft.resourceRegion).isEmpty
            && !trimmed(draft.instanceTagKey).isEmpty
            && !trimmed(draft.instanceTagValue).isEmpty
            && (1...65535).contains(draft.localPort)
            && (1...65535).contains(draft.remotePort)
    }

    private func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Bridges the optional `secretId` to a non-optional text binding (empty == nil).
    private var secretIdBinding: Binding<String> {
        Binding(
            get: { draft.secretId ?? "" },
            set: { draft.secretId = $0.isEmpty ? nil : $0 }
        )
    }

    private func portField(_ title: String, value: Binding<Int>) -> some View {
        TextField(title, value: value, format: .number.grouping(.never))
    }
}
