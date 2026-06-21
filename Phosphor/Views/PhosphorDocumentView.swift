import PhosphorSupport
import SwiftUI

/// Top-level view for a flat `.metal` document. Hands off to
/// ``ShaderEditorView`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var runtime: PhosphorRuntime?
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @SceneStorage("phosphor.ui.showInspector") private var showInspector: Bool = false

    var body: some View {
        ShaderEditorView(
            text: $document.text,
            parsed: document.parsed,
            assets: [:],
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate
        )
        .environment(runtime)
        .task(id: document.parsed) {
            runtime = try? PhosphorRuntime.reloaded(runtime, parsed: document.parsed, assets: [:], audioCapture: audioCapture)
        }
        .inspector(isPresented: $showInspector) {
            PhosphorInspectorView(parsed: document.parsed, runtime: runtime, text: $document.text)
        }
    }
}
