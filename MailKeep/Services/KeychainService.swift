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

    // MARK: - Account List (synchronous, for use during BackupManager init)

    private let accountListService = "com.kzahedi.MailKeep.accounts"
    private let accountListAccount = "account-list"

    /// Save the full account list as a JSON blob. Synchronous — safe to call from @MainActor init.
    /// Uses upsert (update if exists, add if not) to avoid data loss if the add step fails.
    nonisolated func saveAccountList(_ data: Data) throws {
        let lookupQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountListService,
            kSecAttrAccount as String: accountListAccount
        ]

        let checkStatus = SecItemCopyMatching(lookupQuery as CFDictionary, nil)
        if checkStatus == errSecSuccess {
            // Item exists — update in place (no delete, so no window of data loss)
            let updateAttributes: [String: Any] = [
                kSecValueData as String: data
            ]
            let updateStatus = SecItemUpdate(lookupQuery as CFDictionary, updateAttributes as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw KeychainError.saveFailed(updateStatus)
            }
        } else {
            // Item does not exist — add it
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: accountListService,
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

    /// Load the account list JSON blob. Returns nil if not present.
    nonisolated func loadAccountList() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountListService,
            kSecAttrAccount as String: accountListAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    /// Delete the account list entry. Silent if not present.
    nonisolated func deleteAccountList() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: accountListService,
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
