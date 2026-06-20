import PhosphorSupport
import SwiftUI

/// Top-level view for a `.phosphord` bundle document. Three-pane layout:
/// sidebar (shaders) + editor + preview, with the asset thumbnail strip
/// pinned below the editor.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument

    private var sortedShaderNames: [String] {
        document.shaders.keys.sorted()
    }

    /// Two-way binding for the editor's active shader text. Writes flow
    /// back into the dictionary and trigger a re-parse.
    private var activeTextBinding: Binding<String> {
        Binding(
            get: { document.activeText },
            set: { document.activeText = $0 }
        )
    }

    var body: some View {
        NavigationSplitView {
            ShaderSidebar(
                shaderNames: sortedShaderNames,
                selection: Binding(
                    get: { document.activeShader },
                    set: { newValue in
                        if let newValue { document.selectShader(newValue) }
                    }
                ),
                onAdd: { document.addShader() }
            )
        } detail: {
            PhosphorEditorBody(
                text: activeTextBinding,
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
}

/// Left sidebar: list of shaders + a `+` button at the bottom.
private struct ShaderSidebar: View {
    let shaderNames: [String]
    @Binding var selection: String?
    let onAdd: () -> Void

    var body: some View {
        List(selection: $selection) {
            ForEach(shaderNames, id: \.self) { name in
                Label(name, systemImage: "doc.text")
                    .tag(name)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Shaders")
        .safeAreaInset(edge: .bottom) {
            Button(action: onAdd) {
                Label("New Shader", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(.background.secondary)
        }
    }
}
