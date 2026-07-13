import CollaborationKit
import CollaborationKitUI
import Metal
import PhosphorCompile
import PhosphorGeneration
import SwiftUI

/// Coordinates a CollaborationKit ``ConversationStore`` with Phosphor's
/// live shader editor: seeds the tool document from the editor buffer,
/// applies model writes back through the undoable text mutator, and
/// captures per-turn rollback snapshots for the transcript's
/// "Roll Back to Here" action.
///
/// One instance per (document × credentials-backend) pair. Recreated when
/// the user switches backends so the tool loop always uses the current
/// provider.
@MainActor
final class PhosphorConversation {
    /// The CollaborationKit store that drives ``CollaborationChatView``.
    let store: ConversationStore

    /// The tools' view of the .metal source. Kept in sync with the
    /// editor via ``syncSource(_:)``.
    private let document: MetalSourceDocument

    /// Full-text replacement used both by the model's write observer
    /// and by rollback. Runs on the main actor and is expected to route
    /// through Phosphor's undoable ``TextMutator`` so the change lands
    /// as one coalesced undo step.
    private let apply: @MainActor (String, String) -> Void

    init(
        provider: any ModelProvider,
        device: MTLDevice,
        initialSource: String,
        apply: @escaping @MainActor (String, String) -> Void
    ) {
        self.apply = apply

        // Model write observer: fires on a tool-loop thread. Hop to the
        // main actor and re-apply as a named undoable edit so undo
        // history stays coherent.
        let sendableApply: @Sendable (String) -> Void = { newText in
            Task { @MainActor in
                apply(newText, "Generate Shader")
            }
        }
        let document = MetalSourceDocument(source: initialSource, onWrite: sendableApply)
        self.document = document

        let session = LLMSession(
            provider: provider,
            system: GeneratorInstructions.conversationalInstructions,
            tools: .shaderTools(for: document, device: device)
        )
        let store = ConversationStore(
            session: session,
            summarizeTool: PhosphorConversation.summarize(_:)
        )
        self.store = store

        // Rollback: snapshot the current source at send time; on
        // rollback, reseed both the editor and the tools' document.
        // MetalSourceDocument is the tools' single source of truth so
        // reseeding it is enough on the tool side.
        store.snapshotProvider = { [weak self] () -> RollbackSnapshot? in
            guard let self else { return nil }
            let source = (try? self.document.read()) ?? ""
            return RollbackSnapshot { [weak self] in
                guard let self else { return }
                self.apply(source, "Roll Back Shader")
                self.document.setSource(source)
            }
        }
    }

    /// Reseed the tools' view of the source from the editor. Call from
    /// ``ShaderEditorView`` when the user hand-edits the buffer so the
    /// next tool read sees the current text.
    func syncSource(_ text: String) {
        document.setSource(text)
    }

    /// Tears down the event pump and cancels any in-flight turn. Call
    /// before dropping the last reference; @MainActor state can't be
    /// reached from a nonisolated deinit.
    func cancel() {
        store.cancel()
    }

    // MARK: - Presentation

    /// Short, human-readable argument summary for a tool row.
    ///
    /// Handles the three Phosphor-specific tools and delegates the rest
    /// (including the file tools shipped in CollaborationKit) to the
    /// framework default.
    nonisolated static func summarize(_ use: ToolUse) -> String {
        switch use.name {
        case "writeConfiguration":
            return "updating configuration"

        case "readConfiguration":
            return "reading configuration"

        case "compileShader":
            return "compiling"

        default:
            return ConversationStore.defaultSummarize(for: use)
        }
    }

    /// Icon for a tool row. Falls back to ``ConversationRowView``'s
    /// default for the file tools already handled there.
    static func iconForTool(_ name: String) -> String {
        switch name {
        case "writeConfiguration":
            return "slider.horizontal.3"

        case "readConfiguration":
            return "doc.text.magnifyingglass"

        case "compileShader":
            return "hammer"

        default:
            return ConversationRowView.defaultIcon(for: name)
        }
    }

    /// ``ToolPresenterRegistry`` visibility rule tuned to Phosphor:
    ///
    /// - Errors always show.
    /// - `compileShader` only shows the result when it reports failure
    ///   (hides the "Compiles cleanly." success line).
    /// - `readConfiguration` / `read` always show (their content is the
    ///   useful part).
    /// - Other tools hide the result body.
    static func resultVisibility(_ ctx: ToolRowContext) -> Bool {
        if ctx.isError { return true }
        switch ctx.name {
        case "compileShader":
            return ctx.result?.contains("failed") ?? false

        case "readConfiguration", "read":
            return true

        default:
            return false
        }
    }
}
