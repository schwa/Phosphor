import CollaborationKit
import CollaborationKitUI
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Streaming, conversational generation panel hosted in the inspector's
/// "Generate" tab.
///
/// Thin wrapper around ``CollaborationChatView``: the transcript, composer,
/// tool-row rendering, autoscroll, prompt queueing, credentials guard, and
/// debug-log export are all provided by CollaborationKitUI. This wrapper adds
/// Phosphor-specific presentation (tool icons, tool-result visibility rules,
/// the composer's model caption, and the empty-state copy).
///
/// The store is created by the parent editor view — see
/// ``ShaderEditorView`` — and survives inspector tab switches so chat
/// history persists across the "Configuration"/"Output" tabs.
struct GeneratePanel: View {
    let parsed: ParsedPhosphorSource
    /// The persistent conversation coordinator, owned by the editor view.
    /// `nil` before it's been spun up (no credentials, or first mount).
    let conversation: PhosphorConversation?
    /// The live shader source, forwarded into the debug export payload so
    /// bug reports include the exact `.metal` the transcript is talking
    /// about.
    let currentSource: String
    var onGeneratingChange: (Bool) -> Void = { _ in }

    @Environment(CollaborationCredentials.self) private var credentials

    /// Registry with Phosphor-specific visibility rules for tool result
    /// bodies. Held as `@State` so the closure identity stays stable
    /// across re-renders.
    @State private var toolPresenters = ToolPresenterRegistry()
        .resultVisibility(PhosphorConversation.resultVisibility(_:))

    var body: some View {
        content
            .modifier(DebugExportModifier(
                conversation: conversation,
                model: credentials.selectedModel,
                currentSource: currentSource
            ))
    }

    @ViewBuilder
    private var content: some View {
        if let store = conversation?.store {
            CollaborationChatView(
                store: store,
                iconForTool: PhosphorConversation.iconForTool(_:),
                allowsImageAttachments: true,
                onGeneratingChange: onGeneratingChange
            )
            .environment(toolPresenters)
            .collaborationComposerBorderStyle(.glow)
            .collaborationShowsDebugExportButton(true)
            .collaborationEmptyPlaceholder { emptyPlaceholder }
            .collaborationComposerHeader { composerHeader }
            .collaborationMissingCredentialsPlaceholder { missingCredentials }
        } else {
            missingCredentials
        }
    }

    /// Placeholder shown when there are credentials but the user hasn't
    /// sent a message yet.
    private var emptyPlaceholder: some View {
        ContentUnavailableView {
            Label("Generate a Shader", systemImage: "sparkles")
        } description: {
            Text("Describe an effect, e.g. “a swirling galaxy”. The model edits the shader and compiles it as you watch.")
        }
    }

    /// "cpu · Backend · model" caption above the composer.
    private var composerHeader: some View {
        HStack(spacing: 4) {
            Image(systemName: "cpu")
            Text("\(credentials.backend.displayName) · \(credentials.selectedModel)")
            Spacer()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    /// Shown when the selected backend has no stored credentials — either
    /// as the built-in chat view's placeholder, or as our own fallback
    /// while the store hasn't been spun up yet.
    private var missingCredentials: some View {
        ContentUnavailableView {
            Label("Sign in to Generate", systemImage: "key.horizontal")
        } description: {
            Text("Shader generation needs credentials for the selected provider. Add an API key or sign in under Settings → Models.")
        } actions: {
            #if os(macOS)
            SettingsLink {
                Text("Open Settings…")
            }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Installs the debug-log export point only when there is a live store to
/// export. Publishes both an environment action (for the composer's
/// ladybug affordance) and a focused-scene value (for the File menu
/// command).
private struct DebugExportModifier: ViewModifier {
    let conversation: PhosphorConversation?
    let model: String
    let currentSource: String

    func body(content: Content) -> some View {
        if let store = conversation?.store {
            content.collaborationDebugExport(
                store: store,
                model: model,
                userInfo: { ["currentSource": currentSource] }
            )
        } else {
            content
        }
    }
}
