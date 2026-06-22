import PhosphorSupport
import SwiftUI

/// Top-level view for a flat `.metal` document. Hands off to
/// ``ShaderEditorView`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var runtime = PhosphorRuntime()
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        ShaderEditorView(
            text: $document.text,
            parsed: document.parsed,
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate,
            logIdentity: document.fileURL?.absoluteString
        )
        .environment(\.textMutator, TextMutator { newText, actionName in
            document.setText(newText, actionName: actionName, undoManager: undoManager)
        })
        // Debounce recompiles: re-parsing stays instant (cheap, drives editor
        // diagnostics), but the expensive compile waits until typing pauses so
        // mid-edit syntax errors don't flicker back (#53). A new keystroke
        // changes `document.text`, cancelling and restarting this task.
        .task(id: document.text) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            runtime.reload(parsed: document.parsed, assets: [:], audioCapture: audioCapture)
        }
        .environment(runtime)
    }
}
