import PhosphorSupport
import SwiftUI

/// Top-level view for a flat `.metal` document. Hands off to
/// ``PhosphorEditorBody`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument
    @State private var store = PhosphorRuntimeStore()
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @AppStorage("phosphor.ui.showInspector") private var showInspector: Bool = false

    var body: some View {
        PhosphorEditorBody(
            text: $document.text,
            parsed: document.parsed,
            assets: [:],
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate
        )
        .environment(store.runtime)
        .task(id: document.parsed) {
            store.reload(parsed: document.parsed, assets: [:], audioCapture: audioCapture)
        }
        .inspector(isPresented: $showInspector) {
            PhosphorInspector(parsed: document.parsed, runtime: store.runtime)
        }
    }
}
