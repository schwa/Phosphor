import PhosphorSupport
import SwiftUI
import UniformTypeIdentifiers

/// Top-level view for a `.phosphord` bundle document. Sidebar lists the
/// bundled shaders and assets; detail pane is the editor + preview.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument
    @State private var runtime = PhosphorRuntime()
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?

    private var sortedShaderNames: [String] {
        document.shaders.keys.sorted()
    }

    private var sortedAssetNames: [String] {
        document.assets.keys.sorted()
    }

    private var assetNames: Set<String> {
        Set(document.assets.keys)
    }

    private var activeTextBinding: Binding<String> {
        Binding(
            get: { document.activeText },
            set: { document.activeText = $0 }
        )
    }


    var body: some View {
        NavigationSplitView {
            BundleSidebar(
                shaderNames: sortedShaderNames,
                assetNames: sortedAssetNames,
                selection: Binding(
                    get: { document.activeShader },
                    set: { newValue in
                        if let newValue { document.selectShader(newValue) }
                    }
                ),
                onAddShader: { document.addShader() },
                onImport: { urls in importURLs(urls) },
                onDeleteShader: { document.removeShader(filename: $0) },
                onDeleteAsset: { document.removeAsset(name: $0) }
            )
        } detail: {
            ShaderEditorView(
                text: activeTextBinding,
                parsed: document.parsed,
                onTextChange: { document.refreshParsed() },
                isUntouchedTemplate: document.isUntouchedTemplate
            )
        }
        .task(id: ReloadKey(parsed: document.parsed, assetNames: assetNames)) {
            runtime.reload(
                parsed: document.parsed,
                assets: document.assets,
                audioCapture: audioCapture
            )
        }
        .environment(runtime)
    }

    /// Routes a dropped or imported file URL into either the shaders or
    /// assets dict based on its extension. `.metal` becomes a shader;
    /// anything else is treated as an asset.
    private func importURLs(_ urls: [URL]) {
        for url in urls {
            if url.pathExtension.lowercased() == "metal" {
                document.addShader(from: url)
            } else {
                document.addAsset(at: url)
            }
        }
    }
}

/// Sidebar for a `.phosphord` bundle. Two sections (Sources, Assets) plus
/// toolbar buttons at the bottom for "New Shader" and "Import…". Accepts
/// drag-and-drop of `.metal` files (added as shaders) and other files
/// (added as assets).
private struct BundleSidebar: View {
    let shaderNames: [String]
    let assetNames: [String]
    @Binding var selection: String?
    let onAddShader: () -> Void
    let onImport: ([URL]) -> Void
    let onDeleteShader: (String) -> Void
    let onDeleteAsset: (String) -> Void

    @State private var showImporter: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Sources") {
                    ForEach(shaderNames, id: \.self) { name in
                        Label(name, systemImage: "doc.text")
                            .tag(name)
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDeleteShader(name)
                                }
                            }
                    }
                }
                Section("Assets") {
                    ForEach(assetNames, id: \.self) { name in
                        Label(name, systemImage: "photo")
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDeleteAsset(name)
                                }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .dropDestination(for: URL.self) { urls, _ in
                onImport(urls)
                return !urls.isEmpty
            }

            Divider()
            HStack(spacing: 8) {
                Button("New Shader", systemImage: "plus") {
                    onAddShader()
                }
                .help("New Shader")

                Button("Import", systemImage: "square.and.arrow.down") {
                    showImporter = true
                }
                .help("Import a shader or asset")

                Spacer()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.bordered)
            .padding(8)
            .background(.background.secondary)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.metalSource, .image, .data],
                allowsMultipleSelection: true
            ) { result in
                if case .success(let urls) = result {
                    onImport(urls)
                }
            }
        }
        .navigationTitle("Bundle")
    }
}

private struct ReloadKey: Hashable {
    var parsed: ParsedPhosphorSource
    var assetNames: Set<String>
}
