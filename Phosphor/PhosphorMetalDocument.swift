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
    var configuration: URLDocumentConfiguration

    /// Cached parse of `text`. Rebuilt by ``refreshParsed()`` whenever `text`
    /// changes. Stored, not computed, so the parse cost is amortized across
    /// many view reads of `parsed.environment` per frame.
    @ObservationIgnored
    private(set) var parsed: ParsedPhosphorSource

    init(configuration: URLDocumentConfiguration) {
        self.text = ""
        self.configuration = configuration
        self.parsed = ParsedPhosphorSource(source: "")
    }

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
