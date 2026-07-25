import Foundation
import Security

/// One-time migration service from IMAPBackup to MailKeep
/// All methods are synchronous to run before app initialization
enum MigrationService {
    private static let migrationCompletedKey = "MigrationFromIMAPBackupCompleted"
    private static let oldBundleId = "com.kzahedi.IMAPBackup"
    private static let fileSystemMigrationKey = "MigrationFileSystemToMailKeepCompleted"
    private static let backupLocationDefaultsKey = "BackupLocation"

    /// Check if migration is needed and perform it (synchronous)
    static func migrateIfNeeded() {
        // Skip if already migrated
        guard !UserDefaults.standard.bool(forKey: migrationCompletedKey) else {
            return
        }

        // Read old plist file directly
        let prefsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/\(oldBundleId).plist")

        guard FileManager.default.fileExists(atPath: prefsPath.path),
              let oldData = NSDictionary(contentsOf: prefsPath) as? [String: Any],
              oldData["EmailAccounts"] != nil else {
            // No old data, mark as complete
            UserDefaults.standard.set(true, forKey: migrationCompletedKey)
            print("[Migration] No old IMAPBackup data found at \(prefsPath.path), skipping migration")
            return
        }

        print("[Migration] Found old IMAPBackup data, starting migration...")

        // Perform migration
        migrateUserDefaults(from: oldData)
        migrateKeychainItems()

        // Mark complete
        UserDefaults.standard.set(true, forKey: migrationCompletedKey)
        UserDefaults.standard.synchronize()

        print("[Migration] Migration from IMAPBackup to MailKeep completed successfully")
    }

    /// Migrate file system paths from IMAPBackup naming to MailKeep.
    /// Must be called synchronously before BackupManager is initialized.
    static func migrateFileSystemIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: fileSystemMigrationKey) else { return }

        print("[Migration] Starting file system migration to MailKeep...")
        var success = true
        let fm = FileManager.default

        // 1. Migrate App Support directory (contains Logs)
        let appSupport = fm.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask).first!
        let oldAppSupport = appSupport.appendingPathComponent("IMAPBackup")
        let newAppSupport = appSupport.appendingPathComponent("MailKeep")
        let appSupportMigrated = migrateDirectory(from: oldAppSupport, to: newAppSupport, fileManager: fm)
        if !appSupportMigrated {
            success = false
        }
        // Clean up empty source directory only after a successful migration
        if appSupportMigrated && fm.fileExists(atPath: oldAppSupport.path) {
            let remaining = (try? fm.contentsOfDirectory(atPath: oldAppSupport.path)) ?? []
            if remaining.isEmpty {
                try? fm.removeItem(at: oldAppSupport)
            }
        }

        // 2. Migrate backup storage directory
        if let savedPath = UserDefaults.standard.string(forKey: backupLocationDefaultsKey) {
            let oldURL = URL(fileURLWithPath: savedPath)
            if oldURL.lastPathComponent == "IMAPBackup" {
                let newURL = oldURL.deletingLastPathComponent()
                    .appendingPathComponent("MailKeep")
                if fm.fileExists(atPath: oldURL.path) {
                    if migrateDirectory(from: oldURL, to: newURL, fileManager: fm) {
                        UserDefaults.standard.set(newURL.path,
                                                  forKey: backupLocationDefaultsKey)
                        print("[Migration] Updated BackupLocation → \(newURL.path)")
                        // Clean up empty source directory after merge
                        let remaining = (try? fm.contentsOfDirectory(atPath: oldURL.path)) ?? []
                        if remaining.isEmpty {
                            try? fm.removeItem(at: oldURL)
                        }
                    } else {
                        success = false
                    }
                } else {
                    // Source already gone (partial prior run); just update pointer
                    UserDefaults.standard.set(newURL.path,
                                              forKey: backupLocationDefaultsKey)
                    print("[Migration] Source absent, updated BackupLocation pointer")
                }
            }
            // Paths not ending in "IMAPBackup" are custom locations — leave untouched
        }
        // No saved location → fresh install, new code default handles it

        if success {
            UserDefaults.standard.set(true, forKey: fileSystemMigrationKey)
            UserDefaults.standard.synchronize()
            print("[Migration] File system migration completed successfully")
        } else {
            print("[Migration] File system migration had errors — will retry on next launch")
        }
    }

    // MARK: - UserDefaults Migration

    private static func migrateUserDefaults(from oldData: [String: Any]) {
        let keysToMigrate = [
            "EmailAccounts",
            "BackupLocation",
            "BackupSchedule",
            "BackupScheduleTime",
            "BackupHistory",
            "LogLevel",
            "googleOAuthClientId",
            "StreamingThresholdBytes",
            "RateLimitSettings",
            "RateLimitAccountSettings",
            "AttachmentExtractionSettings",
            "RetentionSettings"
        ]

        var migratedCount = 0
        for key in keysToMigrate {
            if let value = oldData[key] {
                UserDefaults.standard.set(value, forKey: key)
                migratedCount += 1
                print("[Migration] Migrated UserDefaults key: \(key)")
            }
        }

        UserDefaults.standard.synchronize()
        print("[Migration] Migrated \(migratedCount) UserDefaults keys")
    }

    // MARK: - Keychain Migration

    private static func migrateKeychainItems() {
        // Migrate password items
        let passwordCount = migrateKeychainService(
            from: "com.kzahedi.IMAPBackup",
            to: "com.kzahedi.MailKeep"
        )
        print("[Migration] Migrated \(passwordCount) password items from Keychain")

        // Migrate OAuth token items
        let oauthCount = migrateKeychainService(
            from: "com.kzahedi.IMAPBackup.oauth",
            to: "com.kzahedi.MailKeep.oauth"
        )
        print("[Migration] Migrated \(oauthCount) OAuth token items from Keychain")
    }

    // MARK: - File System Migration Helpers

    /// Move `oldURL` to `newURL`. If both exist, merges contents (skips conflicts).
    /// Returns true on success or when source doesn't exist (no-op).
    /// Internal (not private) so tests can reach it via @testable import.
    static func migrateDirectory(from oldURL: URL, to newURL: URL,
                                 fileManager: FileManager = .default) -> Bool {
        guard fileManager.fileExists(atPath: oldURL.path) else {
            return true  // nothing to migrate
        }

        if !fileManager.fileExists(atPath: newURL.path) {
            do {
                try fileManager.moveItem(at: oldURL, to: newURL)
                print("[Migration] Renamed \(oldURL.lastPathComponent) → \(newURL.lastPathComponent)")
                return true
            } catch {
                print("[Migration] Failed to rename \(oldURL.path): \(error)")
                return false
            }
        } else {
            return mergeDirectory(from: oldURL, to: newURL, fileManager: fileManager)
        }
    }

    private static func mergeDirectory(from oldURL: URL, to newURL: URL,
                                       fileManager: FileManager) -> Bool {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: oldURL, includingPropertiesForKeys: [.isDirectoryKey]) else {
            print("[Migration] Failed to list contents of \(oldURL.path)")
            return false
        }

        var allSucceeded = true
        for item in contents {
            let dest = newURL.appendingPathComponent(item.lastPathComponent)
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true

            if isDir {
                if fileManager.fileExists(atPath: dest.path) {
                    // Recurse into the existing destination directory
                    if !mergeDirectory(from: item, to: dest, fileManager: fileManager) {
                        allSucceeded = false
                    }
                } else {
                    do {
                        try fileManager.moveItem(at: item, to: dest)
                    } catch {
                        print("[Migration] Failed to move directory \(item.lastPathComponent): \(error)")
                        allSucceeded = false
                    }
                }
            } else {
                // File: skip if already exists at destination (conflict)
                guard !fileManager.fileExists(atPath: dest.path) else { continue }
                do {
                    try fileManager.moveItem(at: item, to: dest)
                } catch {
                    print("[Migration] Failed to move \(item.lastPathComponent): \(error)")
                    allSucceeded = false
                }
            }
        }
        return allSucceeded
    }

    private static func migrateKeychainService(from oldService: String, to newService: String) -> Int {
        // Query all items from old service
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: oldService,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let items = result as? [[String: Any]] else {
            return 0
        }

        var migratedCount = 0

        // Copy each item to new service
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else {
                continue
            }

            // Check if already exists in new service
            let checkQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newService,
                kSecAttrAccount as String: account
            ]

            let checkStatus = SecItemCopyMatching(checkQuery as CFDictionary, nil)
            if checkStatus == errSecSuccess {
                // Already exists, skip
                continue
            }

            // Add to new service
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: newService,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
            ]

            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess {
                migratedCount += 1
            }
        }

        return migratedCount
    }

    // MARK: - Credential Migration (Keychain → file-backed CredentialStore)

    private static let credentialsFileMigrationKey = "CredentialsFileMigrationCompleted"

    /// One-time migration of IMAP passwords and OAuth tokens from the Keychain to the
    /// file-backed CredentialStore. Runs synchronously at startup, before any other
    /// CredentialStore access.
    ///
    /// Retry-safe: the completion flag is set ONLY when every Keychain read either
    /// succeeded or was confirmed empty. A blocked read (errSecInteractionNotAllowed
    /// at Login Item startup after a rebuild changed the code signature) leaves the
    /// flag unset so the migration retries on the next launch — typically a manual
    /// launch where the user can approve the Keychain prompt.
    ///
    /// Keychain items are intentionally left in place (rollback safety).
    static func migrateCredentialsIfNeeded(
        passwordService: String = "com.kzahedi.MailKeep",
        oauthService: String = "com.kzahedi.MailKeep.oauth",
        defaultsKey: String = credentialsFileMigrationKey
    ) {
        guard !UserDefaults.standard.bool(forKey: defaultsKey) else { return }

        let (passwords, passwordsComplete) = readAllKeychainCredentials(service: passwordService)
        let (tokens, tokensComplete) = readAllKeychainCredentials(service: oauthService)

        if !passwords.isEmpty || !tokens.isEmpty {
            do {
                try CredentialStore.importIfAbsent(passwords: passwords, oauthTokens: tokens)
                print("[Migration] Migrated \(passwords.count) password(s) and \(tokens.count) OAuth token(s) from Keychain to file store")
            } catch {
                print("[Migration] Failed to write credentials file: \(error) — will retry next launch")
                return
            }
        }

        if passwordsComplete && tokensComplete {
            UserDefaults.standard.set(true, forKey: defaultsKey)
            UserDefaults.standard.synchronize()
            print("[Migration] Credential migration to file store completed")
        } else {
            print("[Migration] Keychain read was blocked — credential migration will retry next launch")
        }
    }

    /// Read every generic-password item under `service` and flatten to
    /// UUID-string → value. The consolidated "__credential_store__" JSON blob is
    /// expanded and wins over legacy per-UUID items (it is the newer format).
    ///
    /// Uses two-step enumeration (list accounts, then fetch data individually) to work around
    /// a macOS Keychain limitation: combining kSecReturnData with kSecMatchLimitAll on older
    /// systems returns errSecParam. This approach is reliable across OS versions.
    ///
    /// Returns (credentials, complete) where:
    /// - complete=true: enumeration succeeded; all readable items returned; unreachable items
    ///   (errSecItemNotFound after enumeration) are skipped without marking incomplete.
    /// - complete=false: enumeration or any item data fetch failed with a non-notfound error;
    ///   returns whatever could be read safely, and caller must NOT set completion flag.
    internal static func readAllKeychainCredentials(service: String) -> ([String: String], Bool) {
        // Step A: Enumerate accounts without fetching data.
        let listQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var listResult: AnyObject?
        let listStatus = SecItemCopyMatching(listQuery as CFDictionary, &listResult)

        if listStatus == errSecItemNotFound { return ([:], true) }
        guard listStatus == errSecSuccess, let items = listResult as? [[String: Any]] else {
            print("[Migration] Keychain enumeration for \(service) failed with status \(listStatus)")
            return ([:], false)
        }

        var perItem: [String: String] = [:]
        var consolidated: [String: String] = [:]
        var completeRead = true

        // Step B: Fetch data for each account individually.
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }

            let itemQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var itemResult: AnyObject?
            let itemStatus = SecItemCopyMatching(itemQuery as CFDictionary, &itemResult)

            if itemStatus == errSecItemNotFound {
                // Item was deleted between enumeration and fetch; skip without marking incomplete.
                continue
            }

            guard itemStatus == errSecSuccess, let data = itemResult as? Data else {
                print("[Migration] Keychain fetch for \(service)/\(account) failed with status \(itemStatus)")
                completeRead = false
                continue
            }

            if account == "__credential_store__" {
                if let dict = try? JSONDecoder().decode([String: String].self, from: data) {
                    consolidated = dict
                }
            } else if UUID(uuidString: account) != nil,
                      let value = String(data: data, encoding: .utf8) {
                perItem[account] = value
            }
        }

        return (perItem.merging(consolidated) { _, consolidatedValue in consolidatedValue }, completeRead)
    }
}
