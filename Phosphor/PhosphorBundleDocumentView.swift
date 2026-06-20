import PhosphorSupport
import SwiftUI
import Metal

/// Top-level view for a `.phosphord` bundle document. Three-pane layout:
/// sidebar (shaders) + editor + preview, with the asset thumbnail strip
/// pinned below the editor.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument
    @State private var runtime: PhosphorRuntime?
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @AppStorage("phosphor.ui.showInspector") private var showInspector: Bool = false

    private var sortedShaderNames: [String] {
        document.shaders.keys.sorted()
    }

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
        .environment(runtime)
        .task(id: RuntimeKey(parsed: document.parsed, assetNames: Set(document.assets.keys))) {
            await reloadRuntime(parsed: document.parsed, assets: document.assets)
        }
        .inspector(isPresented: $showInspector) {
            PhosphorInspector(parsed: document.parsed, runtime: runtime)
        }
    }

    @MainActor
    private func reloadRuntime(parsed: ParsedPhosphorSource, assets: [String: PhosphorAsset]) {
        guard let environment = parsed.environment else {
            runtime = nil
            return
        }
        do {
            if let runtime {
                try runtime.update(environment: environment, source: parsed.body, assets: assets)
            } else {
                guard let device = MTLCreateSystemDefaultDevice() else { return }
                let newRuntime = try PhosphorRuntime(
                    device: device, environment: environment, source: parsed.body, assets: assets
                )
                newRuntime.audioCapture = audioCapture
                runtime = newRuntime
            }
        } catch {
            print("PhosphorBundleDocumentView: runtime reload failed: \(error)")
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

private struct RuntimeKey: Hashable {
    var parsed: ParsedPhosphorSource
    var assetNames: Set<String>
}
