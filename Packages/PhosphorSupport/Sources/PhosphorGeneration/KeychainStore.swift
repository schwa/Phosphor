import Foundation
import os
import Security

/// Tiny keychain wrapper for generic-password items.
///
/// Used by Phosphor for API key storage (Anthropic and friends). Keyed by a
/// service string + account string; the value is a UTF-8 string.
public enum KeychainStore {
    public static let service = "io.schwa.Phosphor"

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "keychain")

    /// Result of a keychain read, distinguishing "no item" from a transient
    /// failure (e.g. the keychain not yet being available right after login
    /// or under contention). The previous API collapsed both into `nil`,
    /// which made a transient `SecItemCopyMatching` failure look like a
    /// missing key — surfacing as an occasionally-blank API key.
    public enum ReadResult: Equatable {
        case found(String)
        case notFound
        case failed(OSStatus)
    }

    /// Reads a value, distinguishing missing items from transient failures.
    public static func readResult(account: String) -> ReadResult {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                logger.error("Keychain read for account '\(account, privacy: .public)' succeeded but value was not decodable (data present: \(item != nil))")
                return .failed(status)
            }
            logger.debug("Keychain read for account '\(account, privacy: .public)' found a value (\(string.count) chars)")
            return .found(string)

        case errSecItemNotFound:
            logger.info("Keychain read for account '\(account, privacy: .public)': item not found")
            return .notFound

        default:
            // Transient/permission failures (e.g. errSecInteractionNotAllowed)
            // are NOT "no key" — report them so callers can retry rather than
            // silently treating the key as blank. Logged so we can confirm the
            // actual failing status when the "blank key" bug recurs (#63).
            logger.error("Keychain read for account '\(account, privacy: .public)' FAILED with OSStatus \(status) (\(Self.statusMessage(status), privacy: .public))")
            return .failed(status)
        }
    }

    /// Human-readable description for an `OSStatus` from the Security framework.
    private static func statusMessage(_ status: OSStatus) -> String {
        if let message = SecCopyErrorMessageString(status, nil) as String? {
            return message
        }
        return "unknown error"
    }

    /// Reads a value, or nil if the item is not present.
    ///
    /// Note: a transient read *failure* also returns nil here for backwards
    /// compatibility. Callers that need to distinguish "no key" from "couldn't
    /// read the key right now" should use ``readResult(account:)`` instead.
    public static func read(account: String) -> String? {
        if case .found(let value) = readResult(account: account) {
            return value
        }
        return nil
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

        // Add new. Use AfterFirstUnlock so the item stays readable after the
        // first unlock following a reboot, including from background/early
        // launch paths — avoids transient "item unavailable" reads.
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
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
    /// JSON-encoded `OAuthCredentials` for a Claude subscription login.
    public static let anthropicOAuth = "anthropic.oauth"
}
