import Combine
import Foundation
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Document model for a `.phosphord` bundle (file package).
///
/// Layout on disk:
///
///     Foo.phosphord/
///       shaders/
///         hello.metal
///         plasma.metal
///         ...
///       assets/         # optional, embedded textures/audio
///
/// A bundle holds one or more `.metal` shaders. The view picks one at a
/// time to edit; the document keeps every shader's text in memory and
/// writes the whole tree back on save.
@Observable
final class PhosphorBundleDocument: ReferenceFileDocument, ObservableObject {
    /// See `PhosphorMetalDocument.objectWillChange`.
    @ObservationIgnored let objectWillChange = ObservableObjectPublisher()

    static let readableContentTypes: [UTType] = [.phosphorBundle]
    static let writableContentTypes: [UTType] = [.phosphorBundle]

    /// All shaders in the bundle keyed by filename (e.g. `"hello.metal"`).
    var shaders: [String: String]

    /// Filename of the shader currently shown in the editor. nil only
    /// briefly before the first shader is selected on read.
    var activeShader: String?

    /// Cached parse of the active shader's text. Rebuilt by
    /// ``refreshParsed()``.
    @ObservationIgnored
    private(set) var parsed: ParsedPhosphorSource

    /// Bundled image / audio assets keyed by name (filename without
    /// extension). Shared across all shaders in the bundle.
    var assets: [String: PhosphorAsset]

    /// Backing file URL when opened from / saved to disk. Set by the document
    /// view from `DocumentGroup`'s configuration.
    var fileURL: URL?

    /// Key for the active shader's on-disk generation transcript log (#99):
    /// the bundle URL plus the active shader name, or `nil` for an unsaved
    /// bundle (transcript kept in memory only).
    var logIdentity: String? {
        guard let url = fileURL, let shader = activeShader else { return nil }
        return "\(url.absoluteString)#\(shader)"
    }

    /// The `FileWrapper` representing the last successful read or write.
    /// Carried across saves so unchanged children survive incremental
    /// writes without us having to materialize them again.
    @ObservationIgnored
    private var previousFileWrapper: FileWrapper?

    /// Creates a brand-new bundle seeded with one starter shader.
    init() {
        self.shaders = [Self.defaultShaderFilename: Self.template]
        self.activeShader = Self.defaultShaderFilename
        self.parsed = ParsedPhosphorSource(source: Self.template)
        self.assets = [:]
    }

    /// Text of the active shader. Returns "" when no shader is active.
    var activeText: String {
        get { shaders[activeShader ?? ""] ?? "" }
        set {
            guard let name = activeShader else { return }
            shaders[name] = newValue
            refreshParsed()
        }
    }

    /// True if the active shader is the unmodified starter template.
    var isUntouchedTemplate: Bool {
        activeText == Self.template
    }

    /// Subdirectory inside the bundle that holds the .metal shaders.
    static let shadersDirectoryName = "shaders"

    /// Subdirectory inside the bundle that holds image / audio assets.
    static let assetsDirectoryName = "assets"

    /// Default filename for the lone shader in a brand-new bundle.
    static let defaultShaderFilename = "Untitled.metal"

    /// Minimal-viable shader used to seed brand-new bundles.
    static var template: String { PhosphorStarterTemplate.source }

    /// Force a fresh parse from the active shader's text.
    func refreshParsed() {
        parsed = ParsedPhosphorSource(source: activeText)
    }

    /// Replace a specific shader's full text as a single undoable step.
    ///
    /// Programmatic mutations (Reformat, Generate, Configuration edits) must
    /// route through here rather than assigning `activeText` directly so
    /// Cmd-Z restores the prior text and Cmd-Shift-Z re-applies. The undo
    /// closure captures the target shader name so undo lands on the right
    /// shader even if the user has since switched; it re-selects that shader
    /// and re-registers itself for redo. Re-parses after the swap.
    @MainActor
    func setText(_ newText: String, for filename: String, actionName: String, undoManager: UndoManager?) {
        guard let previous = shaders[filename], previous != newText else { return }
        shaders[filename] = newText
        if activeShader == filename {
            refreshParsed()
        }
        undoManager?.registerUndo(withTarget: self) { document in
            if document.activeShader != filename {
                document.selectShader(filename)
            }
            document.setText(previous, for: filename, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }

    /// Convenience: mutate the currently active shader. No-op if none active.
    @MainActor
    func setActiveText(_ newText: String, actionName: String, undoManager: UndoManager?) {
        guard let name = activeShader else { return }
        setText(newText, for: name, actionName: actionName, undoManager: undoManager)
    }

    /// Switch the editor to a different shader. Re-parses on the way.
    func selectShader(_ filename: String) {
        guard shaders[filename] != nil else { return }
        activeShader = filename
        refreshParsed()
    }

    /// Add a new untitled shader, make it active, return its filename.
    /// Uses ``template`` for the body. If the chosen name already exists,
    /// appends a number suffix.
    @discardableResult
    func addShader() -> String {
        let filename = uniqueShaderName(forBase: "Untitled")
        shaders[filename] = Self.template
        activeShader = filename
        refreshParsed()
        return filename
    }

    /// Import an existing `.metal` file as a new shader in the bundle.
    /// The file's basename is used as the key, with a numeric suffix on
    /// collision. Returns the filename actually used, or nil on read
    /// failure.
    @discardableResult
    func addShader(from url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let base = url.deletingPathExtension().lastPathComponent
        let filename = uniqueShaderName(forBase: base)
        shaders[filename] = text
        activeShader = filename
        refreshParsed()
        return filename
    }

    /// Removes the shader with the given filename. If it was the active
    /// shader, selects another (alphabetically first) or clears the
    /// selection when none remain. No-op if not present.
    func removeShader(filename: String) {
        guard shaders[filename] != nil else { return }
        shaders.removeValue(forKey: filename)
        if activeShader == filename {
            activeShader = shaders.keys.sorted().first
            refreshParsed()
        }
    }

    /// Renames a shader from `oldName` to `newName` (both full filenames),
    /// preserving its body and keeping it active if it was. No-op if `oldName`
    /// is missing, `newName` is empty, unchanged, or already taken. Undoable.
    @MainActor
    func renameShader(from oldName: String, to newName: String, undoManager: UndoManager?) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let body = shaders[oldName],
              !trimmed.isEmpty,
              trimmed != oldName,
              shaders[trimmed] == nil else { return }

        shaders.removeValue(forKey: oldName)
        shaders[trimmed] = body
        if activeShader == oldName {
            activeShader = trimmed
        }
        refreshParsed()

        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.renameShader(from: trimmed, to: oldName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Rename Shader")
    }

    /// Renames an asset from `oldName` to `newName` (name stems, no extension),
    /// preserving its bytes. No-op if `oldName` is missing, `newName` is empty,
    /// unchanged, or already taken. Undoable.
    @MainActor
    func renameAsset(from oldName: String, to newName: String, undoManager: UndoManager?) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let asset = assets[oldName],
              !trimmed.isEmpty,
              trimmed != oldName,
              assets[trimmed] == nil else { return }

        assets.removeValue(forKey: oldName)
        assets[trimmed] = PhosphorAsset(name: trimmed, data: asset.data)
        refreshParsed()

        undoManager?.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.renameAsset(from: trimmed, to: oldName, undoManager: undoManager)
            }
        }
        undoManager?.setActionName("Rename Asset")
    }

    /// Returns a filename with `.metal` extension not currently in use.
    /// Appends `" N"` before the extension if the base is taken.
    private func uniqueShaderName(forBase base: String) -> String {
        var candidate = "\(base).metal"
        var counter = 2
        while shaders[candidate] != nil {
            candidate = "\(base) \(counter).metal"
            counter += 1
        }
        return candidate
    }

    // MARK: - Assets

    /// Imports a file URL as a new asset, keyed by the file's name stem.
    /// Existing assets with the same key are replaced.
    func addAsset(at url: URL) {
        guard let data = try? Data(contentsOf: url) else { return }
        let name = url.deletingPathExtension().lastPathComponent
        assets[name] = PhosphorAsset(name: name, data: data)
    }

    /// Removes the asset with the given name. No-op if not present.
    func removeAsset(name: String) {
        assets.removeValue(forKey: name)
    }

    // MARK: - Reading

    /// Snapshot type for the bundle: every shader's text + assets + the
    /// prior directory `FileWrapper` so the writer can reuse unchanged
    /// children.
    struct Snapshot: @unchecked Sendable {
        var shaders: [String: String]
        var activeShader: String?
        var assets: [String: PhosphorAsset]
        var previousFileWrapper: FileWrapper?
    }

    init(configuration: ReadConfiguration) throws {
        let snapshot = Self.decode(directory: configuration.file)
        self.shaders = snapshot.shaders
        self.activeShader = snapshot.activeShader
        self.assets = snapshot.assets
        self.previousFileWrapper = snapshot.previousFileWrapper
        self.parsed = ParsedPhosphorSource(source: snapshot.shaders[snapshot.activeShader ?? ""] ?? "")
    }

    /// Pure decode step; exposed so tests can exercise it without going
    /// through `DocumentReader`.
    static func decode(directory: FileWrapper) -> Snapshot {
        let children = directory.fileWrappers ?? [:]

        // Decode shaders/<name>.metal. Each regular .metal file becomes
        // an entry in the dict keyed by its filename.
        var shaders: [String: String] = [:]
        if let shadersDirectory = children[Self.shadersDirectoryName],
           let shaderChildren = shadersDirectory.fileWrappers {
            for (filename, wrapper) in shaderChildren where wrapper.isRegularFile {
                guard filename.hasSuffix(".metal"),
                      let data = wrapper.regularFileContents,
                      let text = String(data: data, encoding: .utf8) else { continue }
                shaders[filename] = text
            }
        }

        // Pick first shader alphabetically as active. None == no shaders
        // in the bundle (we'll show an empty editor).
        let activeShader = shaders.keys.sorted().first

        // Decode `assets/`.
        var assets: [String: PhosphorAsset] = [:]
        if let assetsDirectory = children[Self.assetsDirectoryName],
           let assetChildren = assetsDirectory.fileWrappers {
            for (filename, wrapper) in assetChildren where wrapper.isRegularFile {
                guard let data = wrapper.regularFileContents else { continue }
                let name = (filename as NSString).deletingPathExtension
                assets[name] = PhosphorAsset(name: name, data: data)
            }
        }

        return Snapshot(
            shaders: shaders,
            activeShader: activeShader,
            assets: assets,
            previousFileWrapper: directory
        )
    }

    // MARK: - Writing

    func fileWrapper(snapshot: Snapshot, configuration: WriteConfiguration) throws -> FileWrapper {
        Self.encode(snapshot: snapshot)
    }

    /// Pure encode step; exposed so tests can exercise it without going
    /// through `DocumentWriter`.
    static func encode(snapshot: Snapshot) -> FileWrapper {
        let directory = snapshot.previousFileWrapper
            ?? FileWrapper(directoryWithFileWrappers: [:])

        // Rebuild shaders/ from scratch. Small N; perf isn't a concern.
        if let existing = directory.fileWrappers?[Self.shadersDirectoryName] {
            directory.removeFileWrapper(existing)
        }
        let shadersDirectory = FileWrapper(directoryWithFileWrappers: [:])
        shadersDirectory.preferredFilename = Self.shadersDirectoryName
        for (filename, text) in snapshot.shaders {
            let wrapper = FileWrapper(regularFileWithContents: Data(text.utf8))
            wrapper.preferredFilename = filename
            shadersDirectory.addFileWrapper(wrapper)
        }
        directory.addFileWrapper(shadersDirectory)

        // Rebuild assets/ from scratch.
        if let existingAssets = directory.fileWrappers?[Self.assetsDirectoryName] {
            directory.removeFileWrapper(existingAssets)
        }
        if !snapshot.assets.isEmpty {
            let assetsDirectory = FileWrapper(directoryWithFileWrappers: [:])
            assetsDirectory.preferredFilename = Self.assetsDirectoryName
            for asset in snapshot.assets.values {
                let filename = filenameForAsset(asset)
                let wrapper = FileWrapper(regularFileWithContents: asset.data)
                wrapper.preferredFilename = filename
                assetsDirectory.addFileWrapper(wrapper)
            }
            directory.addFileWrapper(assetsDirectory)
        }

        return directory
    }

    /// Picks the on-disk filename for an asset by sniffing its bytes for a
    /// known image format and appending the matching extension.
    private static func filenameForAsset(_ asset: PhosphorAsset) -> String {
        let extensionGuess: String?
        let header = asset.data.prefix(8)
        if header.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            extensionGuess = "png"
        } else if header.starts(with: [0xFF, 0xD8, 0xFF]) {
            extensionGuess = "jpg"
        } else if header.starts(with: [0x47, 0x49, 0x46]) {
            extensionGuess = "gif"
        } else {
            extensionGuess = nil
        }
        if let ext = extensionGuess {
            return "\(asset.name).\(ext)"
        }
        return asset.name
    }

    func snapshot(contentType _: UTType) throws -> Snapshot {
        Snapshot(
            shaders: shaders,
            activeShader: activeShader,
            assets: assets,
            previousFileWrapper: previousFileWrapper
        )
    }
}

extension UTType {
    /// `.phosphord` file-package documents: a directory holding one or
    /// more `.metal` shaders plus optional embedded assets.
    static let phosphorBundle = UTType(
        exportedAs: "io.schwa.phosphor.bundle",
        conformingTo: .package
    )
}
