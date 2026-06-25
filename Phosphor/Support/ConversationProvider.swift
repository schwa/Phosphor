import CollaborationKit
import Foundation
import PhosphorGeneration

/// Builds the CollaborationKit ``ModelProvider`` that backs conversational
/// generation, dispatching on the backend the user selected in Settings.
///
/// The agentic tool loop needs reliable, schema-validated tool calling, which
/// Anthropic and OpenAI both provide (the on-device / PCC FoundationModels
/// backends do not).
enum ConversationProvider {
    /// Errors surfaced to the user when a provider can't be built.
    enum Failure: LocalizedError {
        case noCredentials
        case missingAPIKey
        case keychainReadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No credentials. Add an API key (or log in with a Claude subscription) in Settings → Models."

            case .missingAPIKey:
                return "No API key for the selected provider. Add one in Settings → Models to use generation."

            case .keychainReadFailed(let status):
                return "Couldn't read the API key from the Keychain (status \(status))."
            }
        }
    }

    /// The Claude model the Anthropic backends talk to.
    static let anthropicModel = AnthropicModel.opus

    /// The OpenAI model used for generation.
    static let openAIModel = "gpt-4o"

    /// The model identifier for the selected backend (used in debug exports).
    static var exportModelLabel: String {
        switch selectedBackend {
        case .claudeSubscription, .anthropicAPI: anthropicModel.id
        case .openAI: openAIModel
        }
    }

    /// The backend the user selected in Settings.
    static var selectedBackend: GenerationBackend {
        GenerationBackend(rawValue: UserDefaults.standard.string(forKey: "phosphor.modelProvider") ?? "")
            ?? .claudeSubscription
    }

    /// Whether usable credentials are stored for the selected backend.
    static var hasCredentials: Bool {
        switch selectedBackend {
        case .claudeSubscription:
            return AnthropicOAuthStore.isLoggedIn

        case .anthropicAPI:
            return hasKey(KeychainAccount.anthropicAPIKey)

        case .openAI:
            return hasKey(KeychainAccount.openAIAPIKey)
        }
    }

    private static func hasKey(_ account: String) -> Bool {
        if case .found(let value) = KeychainStore.readResult(account: account), !value.isEmpty {
            return true
        }
        return false
    }

    /// Builds the provider for the selected backend.
    static func make() throws -> any ModelProvider {
        switch selectedBackend {
        case .claudeSubscription:
            guard AnthropicOAuthStore.isLoggedIn else { throw Failure.noCredentials }
            // CollaborationKit's `AnthropicAuth.oauth` invokes its token closure on
            // the concurrent executor. This target defaults async closures to
            // `nonisolated(nonsending)`, so wrap the provider in an explicit
            // `@concurrent` closure to match and avoid a data-race warning.
            let provider = AnthropicOAuthStore.tokenProvider()
            let auth = AnthropicAuth.oauth { @concurrent in try await provider() }
            return AnthropicProvider(config: AnthropicConfig(auth: auth, model: anthropicModel.id, maxTokens: 8_192))

        case .anthropicAPI:
            let apiKey = try readKey(KeychainAccount.anthropicAPIKey)
            return AnthropicProvider(config: AnthropicConfig(apiKey: apiKey, model: anthropicModel.id, maxTokens: 8_192))

        case .openAI:
            let apiKey = try readKey(KeychainAccount.openAIAPIKey)
            // Disable parallel tool calls: gpt-4o otherwise issues multiple
            // tool calls per turn, which breaks the read -> edit -> compile
            // agentic loop (it would emit a blind edit alongside a config write).
            return OpenAIProvider(config: OpenAIConfig(apiKey: apiKey, model: openAIModel, maxTokens: 8_192, parallelToolCalls: false))
        }
    }

    private static func readKey(_ account: String) throws -> String {
        switch KeychainStore.readResult(account: account) {
        case .found(let value) where !value.isEmpty:
            return value

        case .found, .notFound:
            throw Failure.missingAPIKey

        case .failed(let status):
            throw Failure.keychainReadFailed(status)
        }
    }
}
