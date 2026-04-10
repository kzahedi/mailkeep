import SwiftUI

struct BackupHistoryView: View {
    @StateObject private var historyService = BackupHistoryService.shared
    @State private var selectedEntry: BackupHistoryEntry?
    @State private var filterAccount: String?

    var body: some View {
        VStack(spacing: 0) {
            // Header with filter
            HStack {
                Text("Backup History")
                    .font(.headline)

                Spacer()

                if !historyService.entries.isEmpty {
                    Menu {
                        Button("All Accounts") {
                            filterAccount = nil
                        }
                        Divider()
                        ForEach(uniqueAccounts, id: \.self) { email in
                            Button(email) {
                                filterAccount = email
                            }
                        }
                    } label: {
                        HStack {
                            Text(filterAccount ?? "All Accounts")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                    }
                    .menuStyle(.borderlessButton)

                    Button(action: { historyService.clearHistory() }) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Clear history")
                }
            }
            .padding()

            Divider()

            // History list
            if filteredEntries.isEmpty {
                VStack {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No backup history")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text("Run a backup to see it here")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedEntry) {
                    ForEach(filteredEntries) { entry in
                        HistoryEntryRow(entry: entry)
                            .tag(entry)
                    }
                }
                .listStyle(.inset)
            }

            // Detail view for selected entry
            if let entry = selectedEntry, !entry.errors.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Errors (\(entry.errors.count))")
                            .font(.subheadline.bold())
                        Spacer()
                        Button("Close") {
                            selectedEntry = nil
                        }
                        .buttonStyle(.borderless)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(entry.errors.indices, id: \.self) { index in
                                Text(entry.errors[index])
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 100)
                }
                .padding()
                .background(Color(nsColor: .controlBackgroundColor))
            }
        }
    }

    var filteredEntries: [BackupHistoryEntry] {
        if let filter = filterAccount {
            return historyService.entries.filter { $0.accountEmail == filter }
        }
        return historyService.entries
    }

    var uniqueAccounts: [String] {
        Array(Set(historyService.entries.map { $0.accountEmail })).sorted()
    }
}

struct HistoryEntryRow: View {
    let entry: BackupHistoryEntry

    var body: some View {
        HStack(spacing: 12) {
            // Status icon
            Image(systemName: entry.status.icon)
                .foregroundStyle(statusColor)
                .font(.title2)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.accountEmail)
                        .font(.subheadline.bold())
                        .lineLimit(1)

                    Spacer()

                    Text(entry.startTime, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 16) {
                    Label("\(entry.emailsDownloaded)", systemImage: "envelope.fill")
                    Label(entry.bytesFormatted, systemImage: "arrow.down.circle.fill")
                    Label(entry.durationFormatted, systemImage: "clock.fill")

                    if !entry.errors.isEmpty {
                        Label("\(entry.errors.count)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    var statusColor: Color {
        switch entry.status {
        case .inProgress: return .blue
        case .completed: return .green
        case .completedWithErrors: return .orange
        case .failed: return .red
        case .cancelled: return .gray
        }
    }
}

#Preview {
    BackupHistoryView()
        .frame(width: 500, height: 400)
}
