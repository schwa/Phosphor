import PhosphorSupport
import SwiftUI

/// Top-level view for a flat `.metal` document. Hands off to
/// ``PhosphorEditorBody`` so the bundle-document variant can share the
/// same UI.
struct PhosphorDocumentView: View {
    @Bindable var document: PhosphorMetalDocument

    var body: some View {
        PhosphorEditorBody(
            text: $document.text,
            parsed: document.parsed,
            assets: [:],
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate,
            editorAccessory: { EmptyView() }
        )
    }
}
