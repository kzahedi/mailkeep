import Foundation
import Security

/// One-time migration service from IMAPBackup to MailKeep
/// All methods are synchronous to run before app initialization
enum MigrationService {
    private static let migrationCompletedKey = "MigrationFromIMAPBackupCompleted"
    private static let oldBundleId = "com.kzahedi.IMAPBackup"

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
