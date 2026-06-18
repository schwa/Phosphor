import Foundation
import PhosphorSupport
import SwiftUI
import UniformTypeIdentifiers

/// Document model for a Phosphor `.metal` source file.
///
/// Reads and writes UTF-8 text via the SDK 27 `ReadableDocument` /
/// `WritableDocument` protocols. The body is a single `text` property; the
/// parsed view (front-matter + body split) is recomputed on demand.
@Observable
final class PhosphorMetalDocument: ReadableDocument, WritableDocument {
    static let readableContentTypes: [UTType] = [.metalSource]
    static let writableContentTypes: [UTType] = [.metalSource]

    var text: String

    /// Backing file URL when the document is opened from / saved to disk.
    /// Brand-new documents and preview instances have `nil`.
    var fileURL: URL?

    /// Cached parse of `text`. Rebuilt by ``refreshParsed()`` whenever `text`
    /// changes. Stored, not computed, so the parse cost is amortized across
    /// many view reads of `parsed.environment` per frame.
    @ObservationIgnored
    private(set) var parsed: ParsedPhosphorSource

    init(configuration: URLDocumentConfiguration) {
        // For brand-new documents (no backing file yet), seed with a minimal
        // working shader so the user has somewhere to start. Documents being
        // read from disk get their text replaced by `apply(snapshot:previous:)`
        // before the view ever sees it.
        let initialText = configuration.fileURL == nil ? Self.template : ""
        self.text = initialText
        self.fileURL = configuration.fileURL
        self.parsed = ParsedPhosphorSource(source: initialText)
    }

    /// Minimal-viable shader used to seed brand-new documents.
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
            constant Uniforms&              uniforms       [[buffer(0)]],
            device const UserUniforms*      userUniforms   [[buffer(2)]],
            uint2 gid                                      [[thread_position_in_grid]])
        {
            float2 uv = float2(gid) / uniforms.resolution;
            outTexture.write(float4(uv.x, uv.y, 0.5 + 0.5 * sin(uniforms.time), 1.0), gid);
        }

        """

    /// Force a fresh parse from `text`. Call after any mutation that should
    /// be reflected in `parsed`.
    func refreshParsed() {
        parsed = ParsedPhosphorSource(source: text)
    }

    // MARK: - ReadableDocument

    func reader(
        configuration: sending DocumentReadConfiguration
    ) -> sending FileWrapperDocumentReader<String> {
        FileWrapperDocumentReader(configuration) { fileWrapper in
            guard let data = fileWrapper.regularFileContents,
                  let text = String(data: data, encoding: .utf8) else {
                return ""
            }
            return text
        }
    }

    @MainActor
    func apply(snapshot: String, previous: String?) async throws {
        self.text = snapshot
        refreshParsed()
    }

    // MARK: - WritableDocument

    func writer(
        configuration: sending DocumentWriteConfiguration
    ) -> sending FileWrapperDocumentWriter<String> {
        FileWrapperDocumentWriter(configuration) { snapshot in
            FileWrapper(regularFileWithContents: Data(snapshot.utf8))
        }
    }

    @MainActor
    func snapshot(contentType: UTType) async throws -> String { text }
}

extension UTType {
    /// `.metal` Metal source files. We declare this as a conformance of
    /// `public.source-code` since macOS already recognizes the extension.
    static let metalSource = UTType(importedAs: "com.apple.metal-shader-source", conformingTo: .sourceCode)
}
