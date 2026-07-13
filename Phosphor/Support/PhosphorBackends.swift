import CollaborationKit
import CollaborationKitUI
import Foundation

/// Phosphor's model-provider registry, wired to CollaborationKit's built-in
/// backends with one Phosphor-specific tweak: the OpenAI backend disables
/// parallel tool calls so the read → edit → compile agentic loop stays
/// sequential (a parallel model would issue a blind `edit` alongside a
/// `writeConfiguration` before it has seen the current source).
enum PhosphorBackends {
    /// The backends exposed in the Settings picker.
    static let all: [Backend] = [
        .claudeSubscription,
        .anthropicAPI,
        .openAI(parallelToolCalls: false)
    ]

    /// The Keychain service string Phosphor has always used. Passing this to
    /// ``KeychainCredentialStore`` lets CollaborationKit read (and update in
    /// place) the API keys and OAuth blob users saved under prior versions —
    /// account names already match CollaborationKit's `CredentialStoreKey`.
    static let keychainService = "io.schwa.Phosphor"

    /// The `UserDefaults` key Phosphor has always used for the picker
    /// selection. Kept so switching to CollaborationKit doesn't reset it.
    static let backendDefaultsKey = "phosphor.modelProvider"
}
