import CollaborationKit
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Top-level Settings scene content. Currently just one pane: model provider
/// configuration.
struct SettingsView: View {
    var body: some View {
        ModelsSettingsView()
            .frame(width: 480, height: 440)
    }
}

/// Supported model providers for shader generation. Anthropic is offered two
/// ways (a Claude.ai subscription login, or a billed API key); OpenAI is a
/// placeholder for an upcoming backend.
enum GenerationBackend: String, CaseIterable, Identifiable {
    case claudeSubscription
    case anthropicAPI
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeSubscription: "Claude Subscription"
        case .anthropicAPI: "Anthropic API"
        case .openAI: "OpenAI"
        }
    }
}

/// A Claude subscription (OAuth) login section: log in via the browser paste
/// flow, or log out. Used in preference to the API key when present.
private struct AnthropicSubscriptionSection: View {
    @Environment(CredentialsModel.self) private var credentials
    @State private var isLoggedIn = AnthropicOAuthStore.isLoggedIn
    @State private var loginRequest: AnthropicOAuth.LoginRequest?
    @State private var pastedCode = ""
    @State private var error: String?
    @State private var isCompleting = false

    private let oauth = AnthropicOAuth()

    var body: some View {
        Section {
            if isLoggedIn {
                HStack {
                    Label("Logged in with a Claude subscription", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Button("Log Out", role: .destructive) {
                        AnthropicOAuthStore.clear()
                        isLoggedIn = false
                        credentials.refresh()
                    }
                }
            } else if let loginRequest {
                Text("A browser window opened. After approving, paste the `code#state` value shown back here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                TextField("Paste code#state", text: $pastedCode)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { complete(loginRequest) }
                HStack {
                    Button("Complete Login") { complete(loginRequest) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCompleting)
                    Button("Cancel") {
                        self.loginRequest = nil
                        pastedCode = ""
                        error = nil
                    }
                    if isCompleting {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
            } else {
                Button("Log In with Claude Subscription", systemImage: "person.badge.key") {
                    beginLogin()
                }
            }
            if let error {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.callout)
            }
        } header: {
            Text("Anthropic Subscription")
        } footer: {
            Text("Log in with a Claude subscription instead of a billed API key. Unofficial (uses the Claude Code OAuth client) and may break without notice. Tokens are refreshed automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func beginLogin() {
        error = nil
        let request = oauth.beginLogin()
        loginRequest = request
        NSWorkspace.shared.open(request.authorizeURL)
    }

    private func complete(_ request: AnthropicOAuth.LoginRequest) {
        let input = pastedCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        isCompleting = true
        error = nil
        Task {
            do {
                let newCredentials = try await oauth.completeLogin(input: input, request: request)
                AnthropicOAuthStore.save(newCredentials)
                await MainActor.run {
                    isLoggedIn = true
                    credentials.refresh()
                    loginRequest = nil
                    pastedCode = ""
                    isCompleting = false
                }
            } catch {
                await MainActor.run {
                    self.error = "Login failed: \(error)"
                    isCompleting = false
                }
            }
        }
    }
}

/// Lets the user enter API keys for external Foundation Model backends.
struct ModelsSettingsView: View {
    @AppStorage("phosphor.modelProvider") private var provider: GenerationBackend = .claudeSubscription
    @Environment(CredentialsModel.self) private var credentials

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $provider) {
                    ForEach(GenerationBackend.allCases) { provider in
                        Text(provider.displayName)
                            .tag(provider)
                    }
                }
            } footer: {
                Text("Choose which provider powers shader generation.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            switch provider {
            case .claudeSubscription:
                AnthropicSubscriptionSection()

            case .anthropicAPI:
                AnthropicAPIKeySection()

            case .openAI:
                OpenAIAPIKeySection()
            }
        }
        .formStyle(.grouped)
        // The active backend determines whether credentials exist; refresh so
        // the Generate panel reflects the switch.
        .onChange(of: provider) { _, _ in credentials.refresh() }
    }
}

/// Anthropic billed API-key credentials.
private struct AnthropicAPIKeySection: View {
    @Environment(CredentialsModel.self) private var credentials
    @State private var anthropicKey: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?

    var body: some View {
        Section {
            SecureField("Anthropic API key", text: $anthropicKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onAppear(perform: loadKey)

            HStack {
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                Button("Clear") {
                    anthropicKey = ""
                    save()
                }
                if savedFlash {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if let readError {
                    Text(readError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
            }
        } header: {
            Text("Anthropic API Key")
        } footer: {
            Link("Get an API key from the Claude Console", destination: URL(string: "https://platform.claude.com/settings/workspaces/default/keys")!)
                .font(.callout)
        }
    }

    private func loadKey() {
        switch KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey) {
        case .found(let value):
            anthropicKey = value

        case .notFound:
            anthropicKey = ""

        case .failed(let status):
            // Don't clobber the field (or let the user think the key is gone)
            // on a transient keychain read failure.
            readError = "Couldn't read the saved key (status \(status)). Try reopening Settings."
        }
    }

    private func save() {
        KeychainStore.write(anthropicKey, account: KeychainAccount.anthropicAPIKey)
        credentials.refresh()
        savedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { savedFlash = false }
        }
    }
}

/// OpenAI billed API-key credentials.
private struct OpenAIAPIKeySection: View {
    @Environment(CredentialsModel.self) private var credentials
    @State private var openAIKey: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?

    var body: some View {
        Section {
            SecureField("OpenAI API key", text: $openAIKey)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onAppear(perform: loadKey)

            HStack {
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                Button("Clear") {
                    openAIKey = ""
                    save()
                }
                if savedFlash {
                    Text("Saved")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
                if let readError {
                    Text(readError)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
            }
        } header: {
            Text("OpenAI API Key")
        } footer: {
            Link("Get an API key from the OpenAI platform", destination: URL(string: "https://platform.openai.com/api-keys")!)
                .font(.callout)
        }
    }

    private func loadKey() {
        switch KeychainStore.readResult(account: KeychainAccount.openAIAPIKey) {
        case .found(let value):
            openAIKey = value

        case .notFound:
            openAIKey = ""

        case .failed(let status):
            readError = "Couldn't read the saved key (status \(status)). Try reopening Settings."
        }
    }

    private func save() {
        KeychainStore.write(openAIKey, account: KeychainAccount.openAIAPIKey)
        credentials.refresh()
        savedFlash = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run { savedFlash = false }
        }
    }
}

#Preview("Settings") {
    SettingsView()
}

#Preview("Models pane") {
    ModelsSettingsView()
        .frame(width: 480, height: 280)
}
