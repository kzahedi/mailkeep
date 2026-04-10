import SwiftUI

struct VerificationResultsListView: View {
    let results: [AccountVerificationResult]

    var body: some View {
        Group {
            ForEach(results, id: \.id) { (result: AccountVerificationResult) in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(result.accountEmail)
                        .font(.headline)
                    Spacer()
                    if result.isFullySynced {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                Text(result.summary)
                    .font(.caption)
                    .foregroundColor(result.isFullySynced ? .secondary : .orange)

                HStack {
                    Text("Server: \(result.totalServerEmails) emails")
                    Text("•")
                    Text("Local: \(result.totalLocalEmails) emails")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                Text("Verified \(result.verifiedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
            }
        }
    }
}

struct VerificationSettingsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @StateObject private var verificationService = VerificationService.shared

    private var verificationResults: [AccountVerificationResult] {
        verificationService.lastResults
    }

    var body: some View {
        Form {
            Section("Backup Verification") {
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Verification compares your local backups with the email server to detect missing emails or emails that have been deleted on the server.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(action: {
                    Task {
                        _ = await verificationService.verifyAll(
                            accounts: backupManager.accounts,
                            backupLocation: backupManager.backupLocation
                        )
                    }
                }) {
                    HStack {
                        if verificationService.isVerifying {
                            ProgressView()
                                .scaleEffect(0.7)
                            Text("Verifying...")
                        } else {
                            Image(systemName: "checkmark.shield")
                            Text("Verify All Accounts")
                        }
                    }
                }
                .disabled(verificationService.isVerifying || backupManager.accounts.isEmpty)

                if verificationService.isVerifying {
                    if let account = verificationService.currentAccount {
                        HStack {
                            Text("Account:")
                                .foregroundStyle(.secondary)
                            Text(account)
                        }
                        .font(.caption)
                    }
                    if let folder = verificationService.currentFolder {
                        HStack {
                            Text("Folder:")
                                .foregroundStyle(.secondary)
                            Text(folder)
                        }
                        .font(.caption)
                    }
                }
            }

            if !verificationResults.isEmpty {
                Section("Last Verification Results") {
                    VerificationResultsListView(results: verificationResults)

                    Button("Clear Results") {
                        verificationService.clearResults()
                    }
                    .buttonStyle(.borderless)
                }

                // Repair section - show when there are missing emails
                if verificationService.hasMissingEmails {
                    Section("Repair Missing Emails") {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("\(verificationService.totalMissingEmails) email(s) missing locally. Click Repair to download them now.")
                                .font(.caption)
                        }

                        Button(action: {
                            Task {
                                _ = await verificationService.repairAll(
                                    accounts: backupManager.accounts,
                                    backupLocation: backupManager.backupLocation
                                )
                            }
                        }) {
                            HStack {
                                if verificationService.isRepairing {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Repairing...")
                                } else {
                                    Image(systemName: "wrench.and.screwdriver")
                                    Text("Repair Missing Emails")
                                }
                            }
                        }
                        .disabled(verificationService.isRepairing || verificationService.isVerifying)

                        if verificationService.isRepairing {
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressView(value: verificationService.repairProgress.progress)
                                    .progressViewStyle(.linear)

                                HStack {
                                    Text("Downloaded: \(verificationService.repairProgress.downloaded)/\(verificationService.repairProgress.totalMissing)")
                                    Spacer()
                                    if verificationService.repairProgress.failed > 0 {
                                        Text("Failed: \(verificationService.repairProgress.failed)")
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.caption)

                                if !verificationService.repairProgress.currentFolder.isEmpty {
                                    Text("Folder: \(verificationService.repairProgress.currentFolder)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                if !verificationService.repairProgress.currentEmail.isEmpty {
                                    Text("Email: \(verificationService.repairProgress.currentEmail)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
            }

            // Repair results section
            if !verificationService.lastRepairResults.isEmpty {
                Section("Last Repair Results") {
                    ForEach(verificationService.lastRepairResults) { result in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(result.accountEmail)
                                    .fontWeight(.medium)
                                Spacer()
                                Text(result.summary)
                                    .font(.caption)
                                    .foregroundStyle(result.failed > 0 ? .orange : .green)
                            }

                            if !result.errors.isEmpty {
                                DisclosureGroup("Show \(result.errors.count) error(s)") {
                                    ForEach(result.errors, id: \.self) { error in
                                        Text(error)
                                            .font(.caption2)
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.caption)
                            }

                            Text("Repaired \(result.repairedAt, style: .relative) ago")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }

                    Button("Clear Repair Results") {
                        verificationService.clearRepairResults()
                    }
                    .buttonStyle(.borderless)
                }
            }

            Section {
                HStack {
                    Image(systemName: "lightbulb.fill")
                        .foregroundStyle(.yellow)
                    Text("Run verification periodically to ensure your backups are complete. Use Repair to download any missing emails immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
