import SwiftUI

/// Connection-log window (H3, F-19): timestamped, category-tagged entries from the in-memory
/// ring buffer. Opened from the "Show Log" menu item. Not persisted to disk.
public struct LogView: View {
    let log: ConnectionLog

    public init(log: ConnectionLog) {
        self.log = log
    }

    public var body: some View {
        VStack(spacing: 0) {
            if log.entries.isEmpty {
                ContentUnavailableView(
                    "No log entries yet",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Connection events appear here as they happen.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(log.entries) { entry in
                                row(for: entry).id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .onChange(of: log.entries.count) { _, _ in
                        if let last = log.entries.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack {
                Text("\(log.entries.count) entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { log.clear() }
                    .disabled(log.entries.isEmpty)
            }
            .padding(8)
        }
        .frame(minWidth: 560, minHeight: 360)
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.timestamp))
                .foregroundStyle(.secondary)
            Text(entry.category.rawValue.uppercased())
                .foregroundStyle(color(for: entry.category))
                .frame(width: 56, alignment: .leading)
            Text(entry.message)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(.caption, design: .monospaced))
    }

    private func color(for category: LogCategory) -> Color {
        switch category {
        case .auth: .purple
        case .ec2: .orange
        case .ssm: .blue
        case .tunnel: .green
        case .ui: .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
