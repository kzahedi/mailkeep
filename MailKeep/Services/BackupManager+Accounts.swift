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

    /// Check all accounts for missing credentials (passwords AND OAuth tokens)
    func checkForMissingPasswords() {
        Task {
            var missing: [EmailAccount] = []
            for account in accounts {
                switch account.authType {
                case .password:
                    let has = await CredentialStore.shared.hasPassword(for: account.id)
                    if !has { missing.append(account) }
                case .oauth2:
                    let has = await CredentialStore.shared.hasOAuthToken(for: account.id)
                    if !has { missing.append(account) }
                }
            }
            await MainActor.run {
                // Union in accounts the credential probe flagged as
                // credential-dead (present-but-rejected-by-server). A
                // presence-only rescan must never silently erase those
                // findings — see BackupManager+CredentialProbe.swift.
                let flaggedIDs = self.probeFlaggedAccountIDs
                if !flaggedIDs.isEmpty {
                    let missingIDs = Set(missing.map(\.id))
                    for account in self.accounts where flaggedIDs.contains(account.id) && !missingIDs.contains(account.id) {
                        missing.append(account)
                    }
                }
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
            try await CredentialStore.shared.savePassword(passwordToSave, for: account.id)
            logInfo("Password saved to credential store for \(account.email)")
        }

        accounts.append(mutableAccount)
        saveAccounts()

        return true
    }

    func removeAccount(_ account: EmailAccount) {
        accounts.removeAll { $0.id == account.id }
        saveAccounts()
        Task { await IDLEManager.shared.stopMonitoring(accountId: account.id) }
        // Remove credentials from the credential store
        Task {
            do {
                try await CredentialStore.shared.deletePassword(for: account.id)
                try await CredentialStore.shared.deleteOAuthTokenString(for: account.id)
            } catch {
                logWarning("Failed to delete credentials for \(account.email): \(error.localizedDescription)")
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
                        try await CredentialStore.shared.savePassword(password, for: account.id)
                    } catch {
                        logError("Failed to update password in credential store for \(account.email): \(error.localizedDescription)")
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
