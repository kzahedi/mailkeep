import Foundation

extension BackupManager {

    // MARK: - Account List Storage

    /// Override the accounts file URL in tests to avoid touching production data.
    /// Set to a temp-directory path in setUp; reset to nil in tearDown.
    nonisolated(unsafe) static var testAccountsFileOverride: URL? = nil

    /// URL of the JSON file that stores the account list.
    /// ~/Library/Application Support/MailKeep/accounts.json
    /// Plain file storage: no ACL, no Keychain dialogs, safe at Login Item startup.
    private var accountsFileURL: URL {
        if let override = Self.testAccountsFileOverride { return override }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MailKeep/accounts.json")
    }

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
        let fileURL = accountsFileURL

        // Primary: JSON file (no Keychain ACL, no dialogs, safe at Login Item startup)
        if let data = try? Data(contentsOf: fileURL) {
            if let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
                accounts = decoded
                logInfo("Loaded \(decoded.count) account(s) from file storage")
                return
            } else {
                logError("loadAccounts: JSON decode failed — accounts file may be corrupt")
            }
        }

        // One-time migration from Keychain (existing installs before file-storage switch)
        let keychain = KeychainService.shared
        if let data = keychain.loadAccountList(),
           let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
            saveAccounts()  // persist to file for future launches
            logInfo("Migrated \(decoded.count) account(s) from Keychain to file storage")
            return
        }

        // One-time migration from UserDefaults (pre-Keychain legacy installs)
        if let data = UserDefaults.standard.data(forKey: accountsKey),
           let decoded = try? JSONDecoder().decode([EmailAccount].self, from: data) {
            accounts = decoded
            saveAccounts()  // persist to file for future launches
            UserDefaults.standard.removeObject(forKey: accountsKey)
            logInfo("Migrated \(decoded.count) account(s) from UserDefaults to file storage")
            return
        }

        logInfo("loadAccounts: no accounts found (new install or first run)")
    }

    func saveAccounts() {
        do {
            let encoded = try JSONEncoder().encode(accounts)
            let fileURL = accountsFileURL
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoded.write(to: fileURL, options: .atomic)
        } catch {
            logError("saveAccounts failed: \(error)")
        }
    }
}
