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
        if !migrateDirectory(from: oldAppSupport, to: newAppSupport, fileManager: fm) {
            success = false
        }
        // Clean up empty source directory after merge
        if fm.fileExists(atPath: oldAppSupport.path) {
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
}
