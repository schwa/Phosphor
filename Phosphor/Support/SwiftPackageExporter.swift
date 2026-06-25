#if os(macOS)
import AppKit
import AppleArchive
import Foundation
import PhosphorCompile
import PhosphorModel
import System

/// Exports the current shader as a standalone, buildable Swift package.
///
/// The package is shipped as a bundled Apple Archive (`PhosphorShaderPackage.aar`)
/// built from `Templates/PhosphorShaderPackage` (see `just encode-template`). It
/// depends on PhosphorKit and renders the embedded `Shader.phosphor` via
/// `PhosphorView(named:)`. Export expands the archive into a user-chosen folder,
/// then overwrites the bundled `Shader.phosphor` with the current document's
/// source — proving the embed-and-link integration contract.
enum SwiftPackageExporter {
    /// Name of the expanded package directory and the archive resource.
    static let packageName = "PhosphorShaderPackage"

    /// Path, inside the package, of the embedded shader resource that gets
    /// replaced with the current document.
    static let shaderResourceRelativePath = "Sources/PhosphorShaderPackage/Resources/Shader.phosphor"

    /// Runs the full export flow: prompt for a destination, expand the template,
    /// and swap in `phosphorJSON` (the current document encoded as `.phosphor`).
    @MainActor
    static func export(phosphorJSON: Data) {
        guard let archive = Bundle.main.url(forResource: packageName, withExtension: "aar") else {
            NSApp.presentError(CocoaError(.fileNoSuchFile))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export Here"
        panel.message = "Choose where to save the Swift package."
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let destination = directory.appendingPathComponent(packageName)
        do {
            if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try extractArchive(at: archive, into: destination)

            // Swap the bundled shader for the current document's source.
            let shaderURL = destination.appendingPathComponent(shaderResourceRelativePath)
            try phosphorJSON.write(to: shaderURL)

            NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Extracts an Apple Archive (`.aar`) into `destination` using the system
    /// `AppleArchive` framework.
    static func extractArchive(at archive: URL, into destination: URL) throws {
        guard let archivePath = FilePath(archive),
              let readStream = ArchiveByteStream.fileStream(
                path: archivePath,
                mode: .readOnly,
                options: [],
                permissions: FilePermissions(rawValue: 0o644)
              ) else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { try? readStream.close() }

        guard let decompressStream = ArchiveByteStream.decompressionStream(readingFrom: readStream) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { try? decompressStream.close() }

        guard let decodeStream = ArchiveStream.decodeStream(readingFrom: decompressStream) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { try? decodeStream.close() }

        guard let destinationPath = FilePath(destination),
              let extractStream = ArchiveStream.extractStream(
                extractingTo: destinationPath,
                flags: [.ignoreOperationNotPermitted]
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? extractStream.close() }

        _ = try ArchiveStream.process(readingFrom: decodeStream, writingTo: extractStream)
    }

    /// Encodes embedded-front-matter `.metal` text into `.phosphor` JSON
    /// (config split from clean source), matching `PhosphorMetalDocument`'s
    /// writer.
    static func phosphorJSON(fromMetalText text: String) throws -> Data {
        let parsed = ParsedPhosphorSource(source: text)
        let document = PhosphorDocument(configuration: parsed.configuration, source: parsed.body)
        return try document.jsonData()
    }
}
#endif
