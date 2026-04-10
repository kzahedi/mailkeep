import Foundation

extension BackupManager {

    // MARK: - Password Management

    /// Check all accounts for missing passwords
    func checkForMissingPasswords() {
        Task {
            var missing: [EmailAccount] = []
            for account in accounts {
                // Only check password-based accounts, not OAuth
                guard account.authType == .password else { continue }

                let hasPassword = await KeychainService.shared.hasPassword(for: account.id)
                if !hasPassword {
                    missing.append(account)
                }
            }

            await MainActor.run {
                self.accountsWithMissingPasswords = missing
            }
        }
    }

    // MARK: - Account Management

    @discardableResult
    func addAccount(_ account: EmailAccount, password: String?) async throws -> Bool {
        // Check for duplicate email address
        if accounts.contains(where: { $0.email.lowercased() == account.email.lowercased() }) {
            logError("Account with email \(account.email) already exists")
            return false
        }

        var mutableAccount = account

        // Save password to Keychain BEFORE publishing the account so that
        // any code running immediately after addAccount() can read credentials.
        let passwordToSave = password ?? mutableAccount.consumeTemporaryPassword()
        if let passwordToSave = passwordToSave {
            try await KeychainService.shared.savePassword(passwordToSave, for: account.id)
            logInfo("Password saved to Keychain for \(account.email)")
        }

        accounts.append(mutableAccount)
        saveAccounts()

        return true
    }

    func removeAccount(_ account: EmailAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        Task { await IDLEManager.shared.stopMonitoring(accountId: account.id) }
        // Remove password from Keychain
        Task {
            do {
                try await KeychainService.shared.deletePassword(for: account.id)
            } catch {
                logWarning("Failed to delete password from Keychain for \(account.email): \(error.localizedDescription)")
            }
        }
    }

    func updateAccount(_ account: EmailAccount, password: String? = nil) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
            saveAccounts()
            restartIDLEMonitoring(for: account)
            // Update password in Keychain if provided
            if let password = password {
                Task {
                    do {
                        try await KeychainService.shared.savePassword(password, for: account.id)
                    } catch {
                        logError("Failed to update password in Keychain for \(account.email): \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func moveAccounts(from source: IndexSet, to destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        saveAccounts()
    }

    func loadAccounts() {
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
        }

        // Uncomment to add a test account for development
        // #if DEBUG
        // if accounts.isEmpty {
        //     let testAccount = EmailAccount.gmail(
        //         email: "your-email@gmail.com",
        //         appPassword: "your-app-password"
        //     )
        //     accounts.append(testAccount)
        // }
        // #endif
    }

    func saveAccounts() {
        do {
            let encoded = try JSONEncoder().encode(accounts)
            UserDefaults.standard.set(encoded, forKey: accountsKey)
        } catch {
            logError("saveAccounts encoding failed: \(error)")
        }
    }
}
