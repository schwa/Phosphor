import CollaborationKit
import Foundation
import PhosphorGeneration

/// Builds the CollaborationKit ``ModelProvider`` that backs conversational
/// generation.
///
/// Conversational mode is Claude-only: the agentic tool loop needs reliable,
/// schema-validated tool calling, which Anthropic provides and the on-device /
/// PCC FoundationModels backends do not. The API key is read from the same
/// Keychain slot the one-shot Anthropic backend uses.
enum ConversationProvider {
    /// Errors surfaced to the user when a provider can't be built.
    enum Failure: LocalizedError {
        case missingAPIKey
        case keychainReadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No Anthropic API key. Add one in Settings → Models to use conversational generation."

            case .keychainReadFailed(let status):
                return "Couldn't read the Anthropic API key from the Keychain (status \(status))."
            }
        }
    }

    /// The Claude model conversational mode talks to.
    static let model = AnthropicModel.opus

    /// Builds an ``AnthropicProvider`` from the stored API key.
    static func make() throws -> AnthropicProvider {
        let apiKey = try readAnthropicKey()
        return AnthropicProvider(config: AnthropicConfig(apiKey: apiKey, model: model.id, maxTokens: 8_192))
    }

    private static func readAnthropicKey() throws -> String {
        switch KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey) {
        case .found(let value) where !value.isEmpty:
            return value

        case .found, .notFound:
            throw Failure.missingAPIKey

        case .failed(let status):
            throw Failure.keychainReadFailed(status)
        }
    }
}
