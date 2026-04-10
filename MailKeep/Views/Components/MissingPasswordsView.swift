import SwiftUI

/// View shown when accounts are missing passwords (e.g., after migration)
struct MissingPasswordsView: View {
    @EnvironmentObject var backupManager: BackupManager
    @Environment(\.dismiss) private var dismiss

    @State private var passwords: [UUID: String] = [:]
    @State private var savingAccount: UUID?
    @State private var errorMessage: String?

    var accountsNeedingPasswords: [EmailAccount] {
        backupManager.accountsWithMissingPasswords
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "key.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)

                Text("Passwords Required")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("The following accounts need their passwords re-entered.\nThis can happen after migrating from a previous version.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top)

            Divider()

            // Account list
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(accountsNeedingPasswords) { account in
                        accountRow(for: account)
                    }
                }
                .padding(.horizontal)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Divider()

            // Footer
            HStack {
                Button("Skip for Now") {
                    dismiss()
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Save All") {
                    saveAllPasswords()
                }
                .buttonStyle(.borderedProminent)
                .disabled(passwords.isEmpty || savingAccount != nil)
            }
            .padding()
        }
        .frame(width: 450, height: 500)
    }

    @ViewBuilder
    private func accountRow(for account: EmailAccount) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: account.imapServer.contains("gmail") ? "envelope.badge.person.crop" : "envelope")
                    .foregroundStyle(.blue)

                Text(account.email)
                    .fontWeight(.medium)

                Spacer()

                if savingAccount == account.id {
                    ProgressView()
                        .scaleEffect(0.7)
                } else if passwords[account.id] != nil && passwords[account.id]!.isEmpty == false {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }

            SecureField("Password", text: binding(for: account.id))
                .textFieldStyle(.roundedBorder)
                .disabled(savingAccount != nil)

            Text(account.imapServer)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func binding(for accountId: UUID) -> Binding<String> {
        Binding(
            get: { passwords[accountId] ?? "" },
            set: { passwords[accountId] = $0 }
        )
    }

    private func saveAllPasswords() {
        errorMessage = nil

        Task {
            for account in accountsNeedingPasswords {
                guard let password = passwords[account.id], !password.isEmpty else {
                    continue
                }

                await MainActor.run {
                    savingAccount = account.id
                }

                do {
                    try await KeychainService.shared.savePassword(password, for: account.id)
                } catch {
                    await MainActor.run {
                        errorMessage = "Failed to save password for \(account.email): \(error.localizedDescription)"
                        savingAccount = nil
                    }
                    return
                }
            }

            await MainActor.run {
                savingAccount = nil
                // Refresh the missing passwords list
                backupManager.checkForMissingPasswords()

                // Dismiss if all passwords are saved
                if backupManager.accountsWithMissingPasswords.isEmpty {
                    dismiss()
                }
            }
        }
    }
}
