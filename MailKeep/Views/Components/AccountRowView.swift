import SwiftUI

struct AccountRowView: View {
    @EnvironmentObject var backupManager: BackupManager
    let account: EmailAccount

    @State private var stats: BackupManager.AccountStats = BackupManager.AccountStats()

    var progress: BackupProgress? {
        backupManager.progress[account.id]
    }

    var body: some View {
        HStack {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .lineLimit(1)

                if let progress = progress, progress.status.isActive {
                    HStack(spacing: 4) {
                        Text(progress.status.rawValue)
                        if let eta = progress.estimatedTimeRemaining, progress.status == .downloading {
                            Text("·")
                            Text(formatDuration(eta))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    // Show stats: email count and size
                    HStack(spacing: 8) {
                        Label("\(stats.totalEmails)", systemImage: "envelope")
                        Label(formatBytes(stats.totalSize), systemImage: "internaldrive")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            // Progress indicator
            if let progress = progress, progress.status.isActive {
                ProgressView(value: progress.progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
            }
        }
        .padding(.vertical, 4)
        .opacity(account.isEnabled ? 1.0 : 0.5)
        .task(id: account.id) {
            // Load stats asynchronously to avoid blocking UI
            stats = await backupManager.getStats(for: account)
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? "--"
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

#Preview {
    List {
        AccountRowView(account: EmailAccount.gmail(email: "test@gmail.com", appPassword: "xxxx"))
    }
    .environmentObject(BackupManager())
}
