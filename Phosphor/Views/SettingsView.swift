import PhosphorModel
import PhosphorCompile
import PhosphorGeneration
import PhosphorRuntime
import SwiftUI

/// Top-level Settings scene content. Currently just one section: API keys
/// for external model backends.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("Models", systemImage: "brain") {
                ModelsSettingsView()
            }
        }
        .frame(width: 480, height: 280)
    }
}

/// Lets the user enter API keys for external Foundation Model backends.
struct ModelsSettingsView: View {
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
                Text("Anthropic")
            } footer: {
                Text("Stored in the macOS Keychain under service \"\(KeychainStore.service)\". Required to use the Anthropic Claude Opus model in the Generate panel.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
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
