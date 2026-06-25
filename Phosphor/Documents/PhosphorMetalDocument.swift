import Combine
import Foundation
import PhosphorCompile
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI
import UniformTypeIdentifiers

/// Document model for a Phosphor `.metal` source file.
///
/// Reads and writes UTF-8 text via `ReferenceFileDocument`. The body is a
/// single `text` property; the parsed view (front-matter + body split) is
/// recomputed on demand.
@Observable
final class PhosphorMetalDocument: ReferenceFileDocument, ObservableObject {
    typealias Snapshot = String

    /// `ReferenceFileDocument` refines `ObservableObject`; provide the publisher
    /// explicitly since the `@Observable` macro drives change tracking and the
    /// default synthesis doesn't fire. SwiftUI observes the document via
    /// `@Bindable`/Observation, not this publisher.
    @ObservationIgnored let objectWillChange = ObservableObjectPublisher()

    static let readableContentTypes: [UTType] = [.phosphorSource, .metalSource]
    static let writableContentTypes: [UTType] = [.phosphorSource, .metalSource]

    var text: String

    /// Backing file URL when the document is opened from / saved to disk.
    /// Set by the document view from `DocumentGroup`'s configuration; brand-new
    /// documents and preview instances have `nil`.
    var fileURL: URL?

    /// Key for the on-disk generation transcript log (#99): the file URL when
    /// saved, else `nil` — unsaved docs keep their transcript in memory only
    /// (a `session:` file could never be re-associated on reopen).
    var logIdentity: String? {
        fileURL?.absoluteString
    }

    /// Cached parse of `text`. Rebuilt by ``refreshParsed()`` whenever `text`
    /// changes. Stored, not computed, so the parse cost is amortized across
    /// many view reads of `parsed.configuration` per frame.
    @ObservationIgnored
    private(set) var parsed: ParsedPhosphorSource

    /// Creates a brand-new document seeded with a minimal working shader so the
    /// user has somewhere to start.
    init() {
        let initialText = Self.template
        self.text = initialText
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

    /// Replace the document's full text as a single undoable step.
    ///
    /// Programmatic mutations (Reformat, Generate, Configuration edits) must
    /// route through here rather than assigning `text` directly so Cmd-Z
    /// restores the prior text and Cmd-Shift-Z re-applies. The undo closure
    /// re-registers itself with the swapped value, giving redo for free.
    /// Re-parses after the swap so `parsed` stays consistent.
    @MainActor
    func setText(_ newText: String, actionName: String, undoManager: UndoManager?) {
        guard newText != text else { return }
        let previous = text
        text = newText
        refreshParsed()
        undoManager?.registerUndo(withTarget: self) { document in
            document.setText(previous, actionName: actionName, undoManager: undoManager)
        }
        undoManager?.setActionName(actionName)
    }

    // MARK: - Reading

    init(configuration: ReadConfiguration) throws {
        let text = Self.decode(configuration: configuration)
        self.text = text
        self.parsed = ParsedPhosphorSource(source: text)
    }

    /// Pure decode step; exposed so tests can exercise it without going through
    /// the document system.
    static func decode(configuration: ReadConfiguration) -> String {
        guard let data = configuration.file.regularFileContents else { return "" }
        // `.phosphor` is the JSON document format (config split from source);
        // reassemble it into embedded-front-matter `.metal` text, which is what
        // the editor and runtime operate on internally.
        if configuration.contentType == .phosphorSource {
            if let document = try? PhosphorDocument(jsonData: data) {
                return Self.metalText(from: document)
            }
            // Fall through: treat as plain text (e.g. a legacy/byte-identical
            // `.phosphor` that predates the JSON format).
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Writing

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        if configuration.contentType == .phosphorSource,
           let data = try? Self.phosphorDocument(from: snapshot).jsonData() {
            return FileWrapper(regularFileWithContents: data)
        }
        return FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }

    // MARK: - `.phosphor` JSON conversion

    /// Reassembles a JSON ``PhosphorDocument`` into the embedded-front-matter
    /// `.metal` text the editor/runtime use internally.
    private static func metalText(from document: PhosphorDocument) -> String {
        guard let body = try? FrontMatterFormatter.encodeBody(document.configuration) else {
            return document.source
        }
        let frontMatter = FrontMatterFormatter.wrapFrontMatter(body: body)
        return "\(frontMatter)\n\n\(document.source)"
    }

    /// Splits embedded-front-matter `.metal` text into a JSON
    /// ``PhosphorDocument`` (config separated from clean source).
    private static func phosphorDocument(from text: String) -> PhosphorDocument {
        let parsed = ParsedPhosphorSource(source: text)
        return PhosphorDocument(configuration: parsed.configuration, source: parsed.body)
    }

    func snapshot(contentType _: UTType) throws -> String { text }
}

extension UTType {
    /// `.metal` Metal source files. We declare this as a conformance of
    /// `public.source-code` since macOS already recognizes the extension.
    static let metalSource = UTType(importedAs: "com.apple.metal-shader-source", conformingTo: .sourceCode)

    /// `.phosphor` single-file Phosphor shaders. A JSON document that keeps the
    /// shader configuration (front-matter) separate from the Metal source
    /// (see `PhosphorDocument`). Distinct from the legacy `.metal` format,
    /// which embeds the configuration as a `/* phosphor:environment */` comment.
    static let phosphorSource = UTType(exportedAs: "io.schwa.phosphor.source", conformingTo: .sourceCode)
}
