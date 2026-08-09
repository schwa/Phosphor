import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Top-level view for a `.phosphord` bundle document. Sidebar lists the
/// bundled shaders and assets; detail pane is the editor + preview.
struct PhosphorBundleDocumentView: View {
    @Bindable var document: PhosphorBundleDocument
    /// Backing file URL supplied by `DocumentGroup`; mirrored onto the document
    /// so `logIdentity` can key the generation transcript.
    let fileURL: URL?
    @State private var runtime = PhosphorRuntime()
    @Environment(AudioCaptureEngine.self) private var audioCapture: AudioCaptureEngine?
    @Environment(\.undoManager) private var undoManager

    private var sortedShaderNames: [String] {
        document.shaders.keys.sorted()
    }

    private var sortedAssetNames: [String] {
        document.assets.keys.sorted()
    }

    private var assetNames: Set<String> {
        Set(document.assets.keys)
    }

    /// What the sidebar has selected. Shaders and assets are separate cases
    /// rather than bare strings so a shader and an asset with the same name
    /// can't be confused for one another.
    @State private var selection: BundleSelection?

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
                    get: { selection ?? document.activeShader.map(BundleSelection.shader) },
                    set: { newValue in
                        selection = newValue
                        // Picking an asset previews it without changing which
                        // shader is being edited, so going back to the editor
                        // lands where you left off.
                        if case .shader(let name) = newValue {
                            document.selectShader(name)
                        }
                    }
                ),
                onAddShader: { document.addShader() },
                onImport: { urls in importURLs(urls) },
                onDeleteShader: { document.removeShader(filename: $0) },
                onDeleteAsset: { document.removeAsset(name: $0) },
                onRenameShader: { document.renameShader(from: $0, to: $1, undoManager: undoManager) },
                onRenameAsset: { document.renameAsset(from: $0, to: $1, undoManager: undoManager) }
            )
        } detail: {
            if case .asset(let name) = selection, let asset = document.assets[name] {
                AssetPreviewView(asset: asset)
            } else {
                ShaderEditorView(
                    text: activeTextBinding,
                    parsed: document.parsed,
                    onTextChange: { document.refreshParsed() },
                    isUntouchedTemplate: document.isUntouchedTemplate,
                    logIdentity: document.logIdentity
                )
                .environment(\.textMutator, TextMutator { newText, actionName in
                    document.setActiveText(newText, actionName: actionName, undoManager: undoManager)
                })
            }
        }
        // Debounce recompiles so mid-edit syntax errors don't flicker back (#53);
        // see PhosphorDocumentView. Keyed on the active text + asset set so a new
        // keystroke (or shader/asset change) cancels and restarts the task.
        .task(id: ReloadKey(text: document.activeText, assetNames: assetNames)) {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            runtime.reload(
                parsed: document.parsed,
                assets: document.assets,
                audioCapture: audioCapture
            )
        }
        .environment(runtime)
        .onAppear { document.fileURL = fileURL }
        .onChange(of: fileURL) { _, newValue in document.fileURL = newValue }
        #if os(macOS)
        .focusedSceneValue(\.exportSwiftPackage, ExportSwiftPackageAction {
            guard let json = try? SwiftPackageExporter.phosphorJSON(fromMetalText: document.activeText) else { return }
            SwiftPackageExporter.export(phosphorJSON: json)
        })
        #endif
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
/// A row in the bundle sidebar. Shaders and assets are distinct cases so
/// same-named entries in the two sections stay distinguishable.
enum BundleSelection: Hashable {
    case shader(String)
    case asset(String)
}

private struct BundleSidebar: View {
    let shaderNames: [String]
    let assetNames: [String]
    @Binding var selection: BundleSelection?
    let onAddShader: () -> Void
    let onImport: ([URL]) -> Void
    let onDeleteShader: (String) -> Void
    let onDeleteAsset: (String) -> Void
    let onRenameShader: (String, String) -> Void
    let onRenameAsset: (String, String) -> Void

    @State private var showImporter: Bool = false
    /// True while a drag is hovering the sidebar, so the drop target can
    /// show it will accept (#64).
    @State private var isDropTargeted: Bool = false
    @State private var searchText: String = ""

    /// Case- and diacritic-insensitive substring filter, matching how Finder
    /// and the rest of the system filter lists.
    private func filtered(_ names: [String]) -> [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return names }
        return names.filter { $0.localizedStandardContains(query) }
    }

    private var hasResults: Bool {
        !filtered(shaderNames).isEmpty || !filtered(assetNames).isEmpty
    }
    /// The row currently being renamed inline, keyed by its name. Nil when no
    /// rename is in progress.
    @State private var renamingName: String?
    @State private var renameText: String = ""
    @FocusState private var renameFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Sources") {
                    ForEach(filtered(shaderNames), id: \.self) { name in
                        renamableRow(name: name, systemImage: "doc.text", commit: onRenameShader)
                            .tag(BundleSelection.shader(name))
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDeleteShader(name)
                                }
                                Button("Rename", systemImage: "pencil") {
                                    beginRename(name)
                                }
                                .tint(.accentColor)
                            }
                    }
                }
                Section("Assets") {
                    ForEach(filtered(assetNames), id: \.self) { name in
                        renamableRow(name: name, systemImage: "photo", commit: onRenameAsset)
                            .tag(BundleSelection.asset(name))
                            .swipeActions(edge: .trailing) {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDeleteAsset(name)
                                }
                                Button("Rename", systemImage: "pencil") {
                                    beginRename(name)
                                }
                                .tint(.accentColor)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $searchText, placement: .sidebar, prompt: "Filter")
            .overlay {
                // Only for an unproductive filter — an empty bundle with no
                // filter typed isn't a "no results" situation.
                if !searchText.isEmpty, !hasResults {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                onImport(urls)
                return !urls.isEmpty
            } isTargeted: { isTargeted in
                isDropTargeted = isTargeted
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.tint, lineWidth: 2)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 8))
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)

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

    /// A list row that shows `name` as a label, or an inline editable text
    /// field while it's being renamed. Commits on Return / focus loss via
    /// `commit(oldName, newName)`; Escape cancels.
    @ViewBuilder
    private func renamableRow(name: String, systemImage: String, commit: @escaping (String, String) -> Void) -> some View {
        if renamingName == name {
            TextField("Name", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .focused($renameFieldFocused)
                .onSubmit { commitRename(commit) }
                .onExitCommand { cancelRename() }
                .onChange(of: renameFieldFocused) { _, focused in
                    if !focused { commitRename(commit) }
                }
        } else {
            Label(name, systemImage: systemImage)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") { beginRename(name) }
                }
        }
    }

    private func beginRename(_ name: String) {
        renamingName = name
        renameText = name
        renameFieldFocused = true
    }

    private func commitRename(_ commit: (String, String) -> Void) {
        guard let oldName = renamingName else { return }
        renamingName = nil
        commit(oldName, renameText)
    }

    private func cancelRename() {
        renamingName = nil
    }
}

private struct ReloadKey: Hashable {
    var text: String
    var assetNames: Set<String>
}
