import Foundation
import Security

/// Service for securely storing credentials in macOS Keychain
actor KeychainService {
    static let shared = KeychainService()

    private let defaultService = "com.kzahedi.MailKeep"

    private init() {}

    // MARK: - Password Management

    /// Save password to Keychain
    /// - Parameters:
    ///   - password: The password to store
    ///   - accountId: The account identifier
    ///   - service: Optional custom service name (defaults to app service)
    func savePassword(_ password: String, for accountId: UUID, service: String? = nil) throws {
        let serviceName = service ?? defaultService
        let account = accountId.uuidString
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.encodingFailed
        }

        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let checkStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        if checkStatus == errSecSuccess {
            // Update in place — no delete/add window where data could be lost
            let updateAttributes: [String: Any] = [kSecValueData as String: passwordData]
            let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
        } else {
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrAccount as String: account,
                kSecValueData as String: passwordData,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
            ]
            let status = SecItemAdd(addQuery as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw KeychainError.saveFailed(status)
            }
        }
    }

    /// Retrieve password from Keychain
    /// - Parameters:
    ///   - accountId: The account identifier
    ///   - service: Optional custom service name (defaults to app service)
    /// - Returns: The stored password
    func getPassword(for accountId: UUID, service: String? = nil) throws -> String {
        let serviceName = service ?? defaultService
        let account = accountId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let passwordData = result as? Data,
              let password = String(data: passwordData, encoding: .utf8) else {
            throw KeychainError.notFound
        }

        return password
    }

    /// Delete password from Keychain
    /// - Parameters:
    ///   - accountId: The account identifier
    ///   - service: Optional custom service name (defaults to app service)
    func deletePassword(for accountId: UUID, service: String? = nil) throws {
        let serviceName = service ?? defaultService
        let account = accountId.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    /// Check if password exists in Keychain
    /// - Parameters:
    ///   - accountId: The account identifier
    ///   - service: Optional custom service name (defaults to app service)
    func hasPassword(for accountId: UUID, service: String? = nil) -> Bool {
        do {
            _ = try getPassword(for: accountId, service: service)
            return true
        } catch {
            return false
        }
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
