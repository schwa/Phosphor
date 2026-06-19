import PhosphorSupport
import SwiftUI

/// Top-level view for a `.phosphor` bundle document. Thin wrapper around
/// ``PhosphorEditorBody`` that also pins the asset thumbnail strip below
/// the source editor.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument

    var body: some View {
        PhosphorEditorBody(
            text: $document.text,
            parsed: document.parsed,
            assets: document.assets,
            onTextChange: { document.refreshParsed() },
            isUntouchedTemplate: document.isUntouchedTemplate,
            editorAccessory: {
                PhosphorAssetStrip(
                    assets: document.assets,
                    onAdd: { urls in urls.forEach(document.addAsset(at:)) },
                    onRemove: { name in document.removeAsset(name: name) }
                )
            }
        )
    }
}
