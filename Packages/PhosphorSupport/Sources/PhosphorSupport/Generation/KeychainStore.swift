import Foundation
import Security

/// Tiny keychain wrapper for generic-password items.
///
/// Used by Phosphor for API key storage (Anthropic and friends). Keyed by a
/// service string + account string; the value is a UTF-8 string.
public enum KeychainStore {
    public static let service = "io.schwa.Phosphor"

    /// Reads a value, or nil if not present.
    public static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// Writes a value. Replaces any existing value for the same account.
    /// Empty `value` deletes the entry.
    @discardableResult
    public static func write(_ value: String, account: String) -> Bool {
        if value.isEmpty {
            return delete(account: account)
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        // Try update first.
        let updateAttrs: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        if updateStatus != errSecItemNotFound { return false }

        // Add new.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        return addStatus == errSecSuccess
    }

    /// Deletes a value. Returns true if it was deleted or already absent.
    @discardableResult
    public static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

/// Account names Phosphor uses inside the Keychain.
public enum KeychainAccount {
    public static let anthropicAPIKey = "anthropic.apiKey"
}
