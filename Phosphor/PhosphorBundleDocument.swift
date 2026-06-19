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

        // Replace shader.metal in place. The other children
        // (currently just a potential `assets/` directory) survive
        // because we keep the same parent wrapper.
        if let existing = directory.fileWrappers?[Self.shaderFilename] {
            directory.removeFileWrapper(existing)
        }
        let shaderData = Data(snapshot.text.utf8)
        let shaderWrapper = FileWrapper(regularFileWithContents: shaderData)
        shaderWrapper.preferredFilename = Self.shaderFilename
        directory.addFileWrapper(shaderWrapper)

        return directory
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
