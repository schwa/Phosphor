import Foundation
import PhosphorSupport
import SwiftUI
import UniformTypeIdentifiers

/// Document model for a `.phosphor` bundle (file package).
///
/// Layout on disk:
///
///     Foo.phosphor/
///       shader.metal   # the active source (front-matter + body)
///       assets/        # optional directory for embedded textures, audio, etc.
///
/// v1 only stores `shader.metal`. The `assets/` subdirectory is reserved
/// for future texture/audio embedding (see #1, #11). For now the bundle is
/// a fancier wrapper around a single source file; the value over flat
/// `.metal` is that it can grow assets without breaking sandbox rules.
@Observable
final class PhosphorBundleDocument: ReadableDocument, WritableDocument {
    static let readableContentTypes: [UTType] = [.phosphorBundle]
    static let writableContentTypes: [UTType] = [.phosphorBundle]

    /// The user's raw Metal source. Same shape as `PhosphorMetalDocument.text`.
    var text: String

    /// Cached parse of `text`. Rebuilt by ``refreshParsed()``.
    @ObservationIgnored
    private(set) var parsed: ParsedPhosphorSource

    /// Bundled image / audio assets keyed by name (filename without
    /// extension). Populated from `assets/` at read time; surfaced to the
    /// runtime so texture resources whose `initial = "image"` resolve
    /// against this map.
    var assets: [String: PhosphorAsset]

    /// Backing file URL when opened from / saved to disk.
    var fileURL: URL?

    /// The `FileWrapper` representing the last successful read or write.
    /// Carried across saves so unchanged children (the still-empty
    /// `assets/` directory, future asset files) survive incremental writes
    /// without us having to materialize them again.
    @ObservationIgnored
    private var previousFileWrapper: FileWrapper?

    init(configuration: URLDocumentConfiguration) {
        let initialText = configuration.fileURL == nil ? Self.template : ""
        self.text = initialText
        self.assets = [:]
        self.fileURL = configuration.fileURL
        self.parsed = ParsedPhosphorSource(source: initialText)
    }

    /// True if `text` is the untouched starter template (used by the
    /// Generate panel to switch between fresh-generation and modify flows).
    var isUntouchedTemplate: Bool {
        text == Self.template
    }

    /// Filename inside the bundle for the active shader source. Stable so
    /// future versions can locate it without a manifest.
    static let shaderFilename = "shader.metal"

    /// Subdirectory inside the bundle that holds image / audio assets.
    static let assetsDirectoryName = "assets"

    /// Minimal-viable shader used to seed brand-new bundles. Mirrors
    /// `PhosphorMetalDocument.template` so the two document types start
    /// from the same place.
    private static let template: String = """
        /* phosphor:environment
        output = "image"

        [[resources]]
        kind = "texture2D"
        id = "image"
        spec = { size = "drawable", format = "rgba32Float", pingPong = false, initial = "zero" }

        [[passes]]
        id = "image"
        output = "image"
        */

        kernel void image(
            texture2d<float, access::write> outTexture     [[texture(0)]],
            device const ChannelBindings&   channels       [[buffer(1)]],
            device const Uniforms*          uniforms       [[buffer(0)]],
            device const UserUniforms*      userUniforms   [[buffer(2)]],
            uint2 gid                                      [[thread_position_in_grid]])
        {
            float2 uv = float2(gid) / uniforms->resolution;
            outTexture.write(float4(uv.x, uv.y, 0.5 + 0.5 * sin(uniforms->time), 1.0), gid);
        }

        """

    /// Force a fresh parse from `text`. Call after any mutation that
    /// should be reflected in `parsed`.
    func refreshParsed() {
        parsed = ParsedPhosphorSource(source: text)
    }

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

    // MARK: - ReadableDocument

    /// Snapshot type for the bundle: source text + assets, plus the prior
    /// directory `FileWrapper` so the writer can reuse unchanged children.
    struct Snapshot: @unchecked Sendable {
        var text: String
        var assets: [String: PhosphorAsset]
        var previousFileWrapper: FileWrapper?
    }

    func reader(
        configuration: sending DocumentReadConfiguration
    ) -> sending FileWrapperDocumentReader<Snapshot> {
        FileWrapperDocumentReader(configuration) { directory in
            Self.decode(directory: directory)
        }
    }

    /// Pure decode step; exposed so tests can exercise it without going
    /// through `DocumentReader`.
    static func decode(directory: FileWrapper) -> Snapshot {
        let children = directory.fileWrappers ?? [:]
        let text: String
        if let data = children[Self.shaderFilename]?.regularFileContents,
           let decoded = String(data: data, encoding: .utf8) {
            text = decoded
        } else {
            text = ""
        }

        // Decode `assets/`. Each regular file becomes a PhosphorAsset
        // keyed by its filename stem (drop extension). Subdirectories
        // and non-regular wrappers are ignored.
        var assets: [String: PhosphorAsset] = [:]
        if let assetsDirectory = children[Self.assetsDirectoryName],
           let assetChildren = assetsDirectory.fileWrappers {
            for (filename, wrapper) in assetChildren where wrapper.isRegularFile {
                guard let data = wrapper.regularFileContents else { continue }
                let name = (filename as NSString).deletingPathExtension
                assets[name] = PhosphorAsset(name: name, data: data)
            }
        }

        return Snapshot(text: text, assets: assets, previousFileWrapper: directory)
    }

    @MainActor
    func apply(snapshot: Snapshot, previous _: Snapshot?) {
        self.text = snapshot.text
        self.assets = snapshot.assets
        self.previousFileWrapper = snapshot.previousFileWrapper
        refreshParsed()
    }

    // MARK: - WritableDocument

    func writer(
        configuration: sending DocumentWriteConfiguration
    ) -> sending FileWrapperDocumentWriter<Snapshot> {
        FileWrapperDocumentWriter(configuration) { snapshot in
            Self.encode(snapshot: snapshot)
        }
    }

    /// Pure encode step; exposed so tests can exercise it without going
    /// through `DocumentWriter`.
    static func encode(snapshot: Snapshot) -> FileWrapper {
        let directory = snapshot.previousFileWrapper
            ?? FileWrapper(directoryWithFileWrappers: [:])

        // Replace shader.metal in place.
        if let existing = directory.fileWrappers?[Self.shaderFilename] {
            directory.removeFileWrapper(existing)
        }
        let shaderData = Data(snapshot.text.utf8)
        let shaderWrapper = FileWrapper(regularFileWithContents: shaderData)
        shaderWrapper.preferredFilename = Self.shaderFilename
        directory.addFileWrapper(shaderWrapper)

        // Materialize the assets/ subdirectory from snapshot.assets.
        // Drop any previous assets/ wrapper and rebuild from the dict so
        // adds and removes both round-trip. (We're writing a small
        // handful of assets; perf isn't a concern yet.)
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
    /// known image format and appending the matching extension. Falls back
    /// to no extension if the format isn't recognized; the bundle reader
    /// keys assets by stem so this still round-trips, just with an ugly
    /// filename.
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

    @MainActor
    func snapshot(contentType _: UTType) -> Snapshot {
        Snapshot(text: text, assets: assets, previousFileWrapper: previousFileWrapper)
    }
}

extension UTType {
    /// `.phosphor` file-package documents: a directory holding `shader.metal`
    /// plus optional embedded assets.
    static let phosphorBundle = UTType(
        exportedAs: "io.schwa.phosphor.bundle",
        conformingTo: .package
    )
}
