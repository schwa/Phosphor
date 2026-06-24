import CollaborationKit
import Foundation
import PhosphorGeneration

/// Stores Claude subscription (OAuth) credentials in the macOS Keychain and
/// supplies a self-refreshing access-token provider for `AnthropicAuth.oauth`.
///
/// CollaborationKit's `OAuthTokenProvider` persists refreshes to its own
/// file-based `CredentialStore`; Phosphor keeps everything in the Keychain, so
/// this wraps the same refresh logic and re-persists to the Keychain slot.
enum AnthropicOAuthStore {
    /// Whether a subscription login is currently stored.
    static var isLoggedIn: Bool {
        load() != nil
    }

    /// Loads the stored credentials, or `nil` if none / unreadable.
    nonisolated static func load() -> OAuthCredentials? {
        guard case .found(let json) = KeychainStore.readResult(account: KeychainAccount.anthropicOAuth),
              let data = json.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(OAuthCredentials.self, from: data) else {
            return nil
        }
        return credentials
    }

    /// Saves credentials to the Keychain.
    @discardableResult
    nonisolated static func save(_ credentials: OAuthCredentials) -> Bool {
        guard let data = try? JSONEncoder().encode(credentials),
              let json = String(data: data, encoding: .utf8) else {
            return false
        }
        return KeychainStore.write(json, account: KeychainAccount.anthropicOAuth)
    }

    /// Removes the stored credentials (logout).
    static func clear() {
        KeychainStore.delete(account: KeychainAccount.anthropicOAuth)
    }

    /// A `@Sendable` access-token provider: returns a valid token, refreshing
    /// via the refresh token when expired and re-persisting to the Keychain.
    static func tokenProvider() -> @Sendable () async throws -> String {
        let oauth = AnthropicOAuth()
        return {
            guard let credentials = load() else {
                throw ConversationProvider.Failure.missingAPIKey
            }
            guard credentials.isExpired() else {
                return credentials.access
            }
            let refreshed = try await oauth.refresh(credentials)
            save(refreshed)
            return refreshed.access
        }
    }
}
