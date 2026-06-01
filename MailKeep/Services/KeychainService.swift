import Foundation
import Security

/// Service for securely storing credentials in macOS Keychain
actor KeychainService {
    static let shared = KeychainService()

    private let defaultService = "com.kzahedi.MailKeep"

    private init() {}

    // MARK: - Consolidated Credential Store
    //
    // All passwords for all accounts are stored in a SINGLE Keychain item per service
    // as a JSON dictionary keyed by UUID string. This means macOS only prompts once
    // (for the store item) regardless of how many accounts are configured.
    //
    // Legacy per-UUID items (from installs before this change) are migrated lazily:
    // the first getPassword() call for each account moves it into the store and
    // deletes the old item. No user action required.

    private let credentialStoreAccount = "__credential_store__"

    private func loadStore(service: String) -> [String: String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialStoreAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }
        return dict
    }

    private func saveStore(_ store: [String: String], service: String) throws {
        guard let data = try? JSONEncoder().encode(store) else {
            throw KeychainError.encodingFailed
        }
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: credentialStoreAccount
        ]
        if SecItemCopyMatching(lookupQuery as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(lookupQuery as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
        } else {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: credentialStoreAccount,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError.saveFailed(status) }
        }
    }

    // MARK: - Password Management

    /// Save password to Keychain (consolidated store — one macOS prompt covers all accounts)
    func savePassword(_ password: String, for accountId: UUID, service: String? = nil) throws {
        let serviceName = service ?? defaultService
        var store = loadStore(service: serviceName)
        store[accountId.uuidString] = password
        try saveStore(store, service: serviceName)
    }

    /// Retrieve password from Keychain.
    /// Checks the consolidated store first. If not found, falls back to the legacy
    /// per-UUID item (pre-consolidation installs) and migrates it into the store.
    func getPassword(for accountId: UUID, service: String? = nil) throws -> String {
        let serviceName = service ?? defaultService

        // Fast path: consolidated store
        let store = loadStore(service: serviceName)
        if let password = store[accountId.uuidString] {
            return password
        }

        // Migration path: legacy per-UUID item
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(legacyQuery as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.notFound
        }

        // Move into consolidated store, remove old item
        var updatedStore = store
        updatedStore[accountId.uuidString] = password
        try? saveStore(updatedStore, service: serviceName)
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId.uuidString
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        return password
    }

    /// Delete password from Keychain (removes from consolidated store and any legacy item)
    func deletePassword(for accountId: UUID, service: String? = nil) throws {
        let serviceName = service ?? defaultService

        var store = loadStore(service: serviceName)
        store.removeValue(forKey: accountId.uuidString)
        try saveStore(store, service: serviceName)

        // Also clean up any legacy per-UUID item that hasn't been migrated yet
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId.uuidString
        ]
        SecItemDelete(legacyQuery as CFDictionary)
    }

    /// Check if a password exists (checks consolidated store, then legacy items)
    func hasPassword(for accountId: UUID, service: String? = nil) -> Bool {
        let serviceName = service ?? defaultService
        let store = loadStore(service: serviceName)
        if store[accountId.uuidString] != nil { return true }
        // Check for unmigrated legacy item without triggering migration
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountId.uuidString
        ]
        return SecItemCopyMatching(legacyQuery as CFDictionary, nil) == errSecSuccess
    }

    /// Migrate password from plaintext to Keychain
    func migratePassword(_ password: String, for accountId: UUID) throws {
        // Only migrate if not already in Keychain
        guard !hasPassword(for: accountId) else { return }
        try savePassword(password, for: accountId)
    }

    // MARK: - Account List (legacy Keychain — used only for one-time migration to file storage)

    private let accountListService = "com.kzahedi.MailKeep.accounts"
    private let accountListAccount = "account-list"

    /// Override the Keychain service name used for the account list.
    /// Set this in tests to an isolated namespace so test runs never touch
    /// the production "com.kzahedi.MailKeep.accounts" entry.
    /// Must be reset to nil in tearDown to avoid leaking into other tests.
    nonisolated(unsafe) static var testServiceOverride: String? = nil

    /// Load the account list JSON blob for one-time migration to file storage.
    /// Checks the data protection keychain first (where recent builds saved it),
    /// then falls back to the legacy keychain (where older builds saved it).
    nonisolated func loadAccountList() -> Data? {
        let serviceName = Self.testServiceOverride ?? accountListService

        // Primary: data protection keychain (where e656b1b and later saved it)
        let dpQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountListAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(dpQuery as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data { return data }

        // Fallback: legacy keychain (where pre-c27961c builds saved it)
        let legacyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountListAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        result = nil
        status = SecItemCopyMatching(legacyQuery as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Save the account list JSON blob to the legacy Keychain.
    /// Retained for test compatibility; production code uses file storage instead.
    nonisolated func saveAccountList(_ data: Data) throws {
        let serviceName = Self.testServiceOverride ?? accountListService
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountListAccount
        ]

        let checkStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        if checkStatus == errSecSuccess {
            let updateAttributes: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
        } else {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: accountListAccount,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError.saveFailed(addStatus)
            }
        }
    }

    /// Delete the account list entry. Silent if not present.
    nonisolated func deleteAccountList() throws {
        let serviceName = Self.testServiceOverride ?? accountListService
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: accountListAccount
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }
}

// MARK: - Errors

enum KeychainError: LocalizedError {
    case encodingFailed
    case saveFailed(OSStatus)
    case notFound
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "Failed to encode password"
        case .saveFailed(let status):
            return "Failed to save to Keychain (status: \(status))"
        case .notFound:
            return "Password not found in Keychain"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain (status: \(status))"
        }
    }
}
