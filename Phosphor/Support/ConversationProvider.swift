import CollaborationKit
import Foundation
import PhosphorGeneration

/// Builds the CollaborationKit ``ModelProvider`` that backs conversational
/// generation, dispatching on the backend the user selected in Settings.
///
/// The agentic tool loop needs reliable, schema-validated tool calling, which
/// the Anthropic and OpenAI backends both provide.
enum ConversationProvider {
    /// Errors surfaced to the user when a provider can't be built.
    enum Failure: LocalizedError {
        case noCredentials
        case missingAPIKey
        case keychainReadFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .noCredentials:
                return "No credentials for the selected provider. Add an API key (or sign in) in Settings → Models."

            case .missingAPIKey:
                return "No API key for the selected provider. Add one in Settings → Models to use generation."

            case .keychainReadFailed(let status):
                return "Couldn't read the API key from the Keychain (status \(status))."
            }
        }
    }

    /// The Claude model the Anthropic backends talk to.
    /// Default model id per backend, used until the user picks one in Settings
    /// (or if model listing isn't available).
    static func defaultModelID(for backend: GenerationBackend) -> String {
        switch backend {
        case .claudeSubscription, .anthropicAPI: "claude-opus-4-8"
        case .openAI: "gpt-4o"
        }
    }

    /// UserDefaults key for the persisted model id of a backend.
    static func modelDefaultsKey(for backend: GenerationBackend) -> String {
        "phosphor.model.\(backend.rawValue)"
    }

    /// The model id the user selected for `backend` (or the default).
    static func selectedModelID(for backend: GenerationBackend) -> String {
        let stored = UserDefaults.standard.string(forKey: modelDefaultsKey(for: backend))
        if let stored, !stored.isEmpty { return stored }
        return defaultModelID(for: backend)
    }

    /// The model identifier for the selected backend (used in debug exports).
    static var exportModelLabel: String {
        selectedModelID(for: selectedBackend)
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
        try makeProvider(for: selectedBackend, model: selectedModelID(for: selectedBackend))
    }

    /// Builds a provider for `backend` using the given model id. Shared by
    /// `make()` and the Settings model-list fetch.
    static func makeProvider(for backend: GenerationBackend, model: String) throws -> any ModelProvider {
        switch backend {
        case .claudeSubscription:
            guard AnthropicOAuthStore.isLoggedIn else { throw Failure.noCredentials }
            // CollaborationKit's `AnthropicAuth.oauth` invokes its token closure on
            // the concurrent executor. This target defaults async closures to
            // `nonisolated(nonsending)`, so wrap the provider in an explicit
            // `@concurrent` closure to match and avoid a data-race warning.
            let provider = AnthropicOAuthStore.tokenProvider()
            let auth = AnthropicAuth.oauth { @concurrent in try await provider() }
            return AnthropicProvider(config: AnthropicConfig(auth: auth, model: model, maxTokens: 8_192))

        case .anthropicAPI:
            let apiKey = try readKey(KeychainAccount.anthropicAPIKey)
            return AnthropicProvider(config: AnthropicConfig(apiKey: apiKey, model: model, maxTokens: 8_192))

        case .openAI:
            let apiKey = try readKey(KeychainAccount.openAIAPIKey)
            // Disable parallel tool calls: gpt-4o otherwise issues multiple
            // tool calls per turn, which breaks the read -> edit -> compile
            // agentic loop (it would emit a blind edit alongside a config write).
            return OpenAIProvider(config: OpenAIConfig(apiKey: apiKey, model: model, maxTokens: 8_192, parallelToolCalls: false))
        }
    }

    /// Fetches the models available for `backend`, filtered to ones usable for
    /// chat + tool-calling generation (providers list embeddings, audio, image,
    /// etc. that can't drive the agentic loop).
    static func listModels(for backend: GenerationBackend) async throws -> [ModelInfo] {
        let provider = try makeProvider(for: backend, model: defaultModelID(for: backend))
        guard let lister = provider as? ModelLister else { return [] }
        let all = try await lister.listModels()
        return all.filter { isChatModel($0.id, backend: backend) }
    }

    /// Heuristic for whether a model id is a chat/tool-capable text model.
    private static func isChatModel(_ id: String, backend: GenerationBackend) -> Bool {
        let lower = id.lowercased()
        // Hide dated snapshot pins (e.g. `...-2025-12-11`); keep clean aliases.
        if hasDateSuffix(lower) { return false }
        switch backend {
        case .claudeSubscription, .anthropicAPI:
            return lower.hasPrefix("claude-")

        case .openAI:
            // Exclude non-text modalities and specialized endpoints.
            let excluded = ["audio", "image", "realtime", "transcribe", "tts",
                            "whisper", "embedding", "moderation", "search",
                            "dall-e", "codex", "computer-use"]
            if excluded.contains(where: lower.contains) { return false }
            // Keep the gpt and o-series reasoning families.
            return lower.hasPrefix("gpt-") || lower.hasPrefix("chatgpt")
                || lower.hasPrefix("o1") || lower.hasPrefix("o3") || lower.hasPrefix("o4")
        }
    }

    /// True if the id ends in a `-YYYY-MM-DD` snapshot date.
    private static func hasDateSuffix(_ id: String) -> Bool {
        id.wholeMatch(of: /.*-\d{4}-\d{2}-\d{2}/) != nil
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
