import Observation
import SwiftUI

/// Observable wrapper around the stored Anthropic credentials, injected into
/// the environment so views (the Generate panel, Settings) react immediately
/// when credentials are added, changed, or cleared.
///
/// The source of truth remains the Keychain (via ``ConversationProvider``);
/// this model just caches the derived `hasCredentials` flag and re-reads it on
/// ``refresh()`` after any mutation.
@Observable
@MainActor
final class CredentialsModel {
    private(set) var hasCredentials: Bool

    init() {
        hasCredentials = ConversationProvider.hasCredentials
    }

    /// Re-reads credential state from the Keychain. Call after saving a key,
    /// logging in, or logging out.
    func refresh() {
        hasCredentials = ConversationProvider.hasCredentials
    }
}
