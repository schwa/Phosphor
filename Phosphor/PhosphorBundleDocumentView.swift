import PhosphorSupport
import SwiftUI

/// Top-level view for a `.phosphor` bundle document. Thin wrapper around
/// ``PhosphorEditorBody`` to keep parity with ``PhosphorDocumentView``.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument

    var body: some View {
        PhosphorEditorBody(
            text: $document.text,
            parsed: document.parsed,
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate
        )
    }
}
