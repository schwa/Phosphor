import PhosphorSupport
import SwiftUI

/// Top-level view for a flat `.metal` document. Hands off to
/// ``ShaderEditorView`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var runtime = PhosphorRuntime()
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?

    var body: some View {
        ShaderEditorView(
            text: $document.text,
            parsed: document.parsed,
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate
        )
        .task(id: document.parsed) {
            runtime.reload(parsed: document.parsed, assets: [:], audioCapture: audioCapture)
        }
        .environment(runtime)
    }
}
