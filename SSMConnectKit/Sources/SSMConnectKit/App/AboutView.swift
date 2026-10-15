import SwiftUI

struct AboutAppInfo: Equatable {
    let name: String
    let version: String?
    let build: String?

    init(dictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        name = Self.text(dictionary["CFBundleDisplayName"])
            ?? Self.text(dictionary["CFBundleName"]) ?? "SSM Connect"
        version = Self.text(dictionary["CFBundleShortVersionString"])
        build = Self.text(dictionary["CFBundleVersion"])
    }

    var versionLabel: String {
        switch (version, build) {
        case let (.some(version), .some(build)): return "Version \(version) (Build \(build))"
        case let (.some(version), .none): return "Version \(version)"
        case let (.none, .some(build)): return "Build \(build)"
        case (.none, .none): return "Development build"
        }
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

public struct AboutView: View {
    private let info: AboutAppInfo
    @State private var showConnectionStates = false

    public init() {
        info = AboutAppInfo()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(info.name).font(.title2.weight(.semibold))
                    Text(info.versionLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                GridRow {
                    Text("System").foregroundStyle(.secondary)
                    Text(ProcessInfo.processInfo.operatingSystemVersionString)
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Architecture").foregroundStyle(.secondary)
                    Text(architecture)
                }
                GridRow {
                    Text("License").foregroundStyle(.secondary)
                    Link("Apache License 2.0", destination: URL(string: "https://github.com/vhco-pro/ssm-connect/blob/main/LICENSE")!)
                }
            }
            .font(.callout)

            HStack(spacing: 24) {
                Link(destination: URL(string: "https://github.com/vhco-pro/ssm-connect")!) {
                    Label("Project", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://github.com/vhco-pro/ssm-connect/releases")!) {
                    Label("Release Notes", systemImage: "shippingbox")
                }
            }
            .font(.callout)

            Divider()

            DisclosureGroup("Connection States", isExpanded: $showConnectionStates) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(ConnectionState.allCases, id: \.self) { state in
                        HStack(spacing: 10) {
                            Image(systemName: state.sfSymbol)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(state.color)
                                .frame(width: 20)
                            Text(state.tooltip)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .font(.callout)
                .padding(.top, 12)
            }
        }
        .padding(24)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var architecture: String {
        #if arch(arm64)
        "Apple Silicon"
        #elseif arch(x86_64)
        "Intel"
        #else
        "Unknown"
        #endif
    }
}