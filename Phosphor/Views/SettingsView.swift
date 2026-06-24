import CollaborationKit
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Top-level Settings scene content. Currently just one section: API keys
/// for external model backends.
struct SettingsView: View {
    var body: some View {
        ModelsSettingsView()
            .frame(width: 480, height: 440)
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
    @Environment(CredentialsModel.self) private var credentials
    @State private var anthropicKey: String = ""
    @State private var savedFlash: Bool = false
    @State private var readError: String?

    var body: some View {
        Form {
            Section {
                SecureField("Anthropic API key", text: $anthropicKey)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)

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
                VStack(alignment: .leading, spacing: 4) {
                    Link("Get an API key from the Claude Console", destination: URL(string: "https://platform.claude.com/settings/workspaces/default/keys")!)
                    Text("A subscription login (below) is used in preference to this key when present.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }

            AnthropicSubscriptionSection()
        }
        .formStyle(.grouped)
        .onAppear {
            switch KeychainStore.readResult(account: KeychainAccount.anthropicAPIKey) {
            case .found(let value):
                anthropicKey = value

            case .notFound:
                anthropicKey = ""

            case .failed(let status):
                // Don't clobber the field (or let the user think the key is
                // gone) on a transient keychain read failure.
                readError = "Couldn't read the saved key (status \(status)). Try reopening Settings."
            }
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

#Preview("Settings") {
    SettingsView()
}

#Preview("Models pane") {
    ModelsSettingsView()
        .frame(width: 480, height: 280)
}
