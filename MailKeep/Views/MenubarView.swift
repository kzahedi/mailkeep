import SwiftUI

struct MenubarView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.openWindow) private var openWindow

    @State private var globalStats: BackupManager.GlobalStats = BackupManager.GlobalStats()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Text("MailKeep")
                    .font(.headline)
                Spacer()
                if backupManager.isBackingUp {
                    ProgressView()
                        .scaleEffect(0.7)
                }
            }

            // Global stats
            HStack(spacing: 16) {
                MenubarStatItem(icon: "envelope.fill", value: "\(globalStats.totalEmails)", label: "emails")
                MenubarStatItem(icon: "internaldrive.fill", value: formatBytes(globalStats.totalSize), label: "total")
                MenubarStatItem(icon: "person.2.fill", value: "\(globalStats.accountCount)", label: "accounts")
            }
            .padding(.vertical, 4)

            Divider()

            // Account statuses
            if backupManager.accounts.isEmpty {
                Text("No accounts configured")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(backupManager.accounts) { account in
                    MenubarAccountRow(account: account)
                }
            }

            Divider()

            // Current backup status
            if backupManager.isBackingUp {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        ProgressView()
                            .scaleEffect(0.6)
                        Text("Backing up...")
                            .font(.caption)
                            .fontWeight(.medium)
                    }

                    // Show overall progress
                    let totalProgress = calculateTotalProgress()
                    ProgressView(value: totalProgress)
                        .progressViewStyle(.linear)

                    Text("\(totalDownloaded()) emails downloaded")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)

                Divider()
            }

            // Schedule info
            HStack {
                Image(systemName: "clock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Menu {
                    ForEach(BackupSchedule.allCases, id: \.self) { scheduleOption in
                        Button(action: {
                            backupManager.setSchedule(scheduleOption)
                        }) {
                            HStack {
                                Text(scheduleOption.rawValue)
                                if backupManager.schedule == scheduleOption {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text(backupManager.schedule.rawValue)
                            .font(.caption)
                        if backupManager.schedule.needsTimeSelection {
                            Text("at \(backupManager.scheduledTimeFormatted)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                    }
                }
                .menuStyle(.borderlessButton)

                Spacer()

                if let nextBackup = backupManager.nextScheduledBackup {
                    Text("Next: \(nextBackup, style: .relative)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Actions
            Button(action: {
                backupManager.startBackupAll()
            }) {
                Label("Backup Now", systemImage: "arrow.clockwise")
            }
            .disabled(backupManager.accounts.isEmpty || backupManager.isBackingUp)
            .buttonStyle(.plain)

            if backupManager.isBackingUp {
                Button(action: {
                    backupManager.cancelAllBackups()
                }) {
                    Label("Cancel Backup", systemImage: "xmark.circle")
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button(action: {
                NSApp.activate(ignoringOtherApps: true)
                // Open main window
                for window in NSApp.windows {
                    if window.title.isEmpty || window.title == "MailKeep" {
                        window.makeKeyAndOrderFront(nil)
                        break
                    }
                }
            }) {
                Label("Open Main Window", systemImage: "macwindow")
            }
            .buttonStyle(.plain)

            Button(action: {
                NSApp.sendAction(#selector(AppDelegate.openSearchWindow), to: nil, from: nil)
                NSApp.activate(ignoringOtherApps: true)
            }) {
                Label("Search Emails...", systemImage: "magnifyingglass")
            }
            .buttonStyle(.plain)
            .keyboardShortcut("f", modifiers: .command)

            SettingsLink {
                Label("Settings...", systemImage: "gear")
            }
            .buttonStyle(.plain)

            Divider()

            Button(action: {
                NSApplication.shared.terminate(nil)
            }) {
                Label("Quit", systemImage: "power")
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(width: 280)
        .task {
            // Load stats asynchronously to avoid blocking UI
            globalStats = await backupManager.getGlobalStats()
        }
    }

    func calculateTotalProgress() -> Double {
        let activeProgress = backupManager.progress.values.filter { $0.status.isActive }
        guard !activeProgress.isEmpty else { return 0 }

        let totalDownloaded = activeProgress.reduce(0) { $0 + $1.downloadedEmails }
        let totalEmails = activeProgress.reduce(0) { $0 + $1.totalEmails }

        guard totalEmails > 0 else { return 0 }
        return Double(totalDownloaded) / Double(totalEmails)
    }

    func totalDownloaded() -> Int {
        backupManager.progress.values.reduce(0) { $0 + $1.downloadedEmails }
    }
}

struct MenubarAccountRow: View {
    @EnvironmentObject var backupManager: BackupManager
    let account: EmailAccount

    var progress: BackupProgress? {
        backupManager.progress[account.id]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                Text(account.email)
                    .font(.caption)
                    .lineLimit(1)

                Spacer()

                if let progress = progress, progress.status.isActive {
                    Text("\(Int(progress.progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if let progress = progress, progress.status.isActive {
                ProgressView(value: progress.progress)
                    .progressViewStyle(.linear)
                    .scaleEffect(y: 0.5)

                if !progress.currentFolder.isEmpty {
                    Text(progress.currentFolder)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if let lastBackup = account.lastBackupDate {
                Text("Last: \(lastBackup, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    var statusColor: Color {
        guard account.isEnabled else { return .gray }

        if let status = progress?.status {
            switch status {
            case .completed: return .green
            case .failed: return .red
            case .cancelled: return .orange
            case .idle: return .gray
            default: return .blue
            }
        }

        return .gray
    }
}

struct MenubarStatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                Text(value)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowedUnits = [.useGB, .useMB]
    return formatter.string(fromByteCount: bytes)
}

#Preview {
    MenubarView()
        .environmentObject(BackupManager())
}
