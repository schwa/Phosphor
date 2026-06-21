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

    /// Returns true if `text` looks like the unmodified starter template that
    /// `init(configuration:)` seeds into brand-new documents. Used by the
    /// Generate panel to treat "hit Cmd-N, then generate" as a fresh
    /// generation rather than a modification of the template.
    var isUntouchedTemplate: Bool {
        text == Self.template
    }

    /// Minimal-viable shader used to seed brand-new documents.
    private static var template: String { PhosphorStarterTemplate.source }

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
    func apply(snapshot: String, previous _: String?) {
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
    func snapshot(contentType _: UTType) -> String { text }
}

extension UTType {
    /// `.metal` Metal source files. We declare this as a conformance of
    /// `public.source-code` since macOS already recognizes the extension.
    static let metalSource = UTType(importedAs: "com.apple.metal-shader-source", conformingTo: .sourceCode)
}
