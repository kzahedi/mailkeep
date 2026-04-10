import SwiftUI

struct RetentionSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @StateObject private var retentionService = RetentionService.shared
    @State private var previewResult: RetentionResult?
    @State private var isApplying = false

    var body: some View {
        Form {
            Section("Retention Policy") {
                Picker("Policy", selection: $retentionService.globalSettings.policy) {
                    ForEach(RetentionPolicy.allCases, id: \.self) { policy in
                        Text(policy.rawValue).tag(policy)
                    }
                }
                .pickerStyle(.radioGroup)

                if retentionService.globalSettings.policy == .byAge {
                    Stepper(
                        "Delete backups older than \(retentionService.globalSettings.maxAgeDays) days",
                        value: $retentionService.globalSettings.maxAgeDays,
                        in: 7...3650,
                        step: 30
                    )

                    Text("Backups older than \(retentionService.globalSettings.maxAgeDays) days will be automatically deleted after each backup run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if retentionService.globalSettings.policy == .byCount {
                    Stepper(
                        "Keep only \(retentionService.globalSettings.maxCount) newest backups",
                        value: $retentionService.globalSettings.maxCount,
                        in: 100...100000,
                        step: 100
                    )

                    Text("Only the \(retentionService.globalSettings.maxCount) most recent email backups will be kept. Older emails will be deleted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Manual Actions") {
                HStack {
                    Button("Preview") {
                        previewResult = retentionService.previewRetention(at: backupManager.backupLocation)
                    }
                    .disabled(retentionService.globalSettings.policy == .keepAll)

                    Button("Apply Now") {
                        isApplying = true
                        Task {
                            _ = await retentionService.applyRetentionToAll(backupLocation: backupManager.backupLocation)
                            await MainActor.run {
                                isApplying = false
                                previewResult = nil
                            }
                        }
                    }
                    .disabled(retentionService.globalSettings.policy == .keepAll || isApplying)

                    if isApplying {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
                }

                if let preview = previewResult {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(.blue)
                        if preview.filesDeleted == 0 {
                            Text("No files would be deleted with current policy.")
                        } else {
                            Text("Would delete \(preview.filesDeleted) files, freeing \(preview.bytesFreedFormatted)")
                        }
                    }
                    .font(.callout)
                }
            }

            Section {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Retention policies permanently delete email backups. Deleted emails cannot be recovered.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
