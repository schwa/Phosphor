/// Mutable, deliberately non-observable holder for the renderer's frame
/// counter. Lives outside `EditorModel` because it changes every frame and
/// nothing should invalidate a view because of it.
@MainActor
final class RenderedFrameCounter {
    var index: UInt32 = 0
}

#if os(macOS)
import AppKit
import PhosphorModel
import PhosphorRuntime
import UniformTypeIdentifiers

/// Save-to-disk and copy-to-clipboard for the rendered frame.
@MainActor
enum FrameExporter {
    static let writableTypes: [UTType] = [.png, .jpeg, .tiff]

    /// Prompts for a destination and writes the captured frame there. The
    /// chosen file extension picks the format; PNG is the default.
    static func save(runtime: PhosphorRuntime, displayedResource: ResourceID?, frameIndex: UInt32) {
        guard let image = FrameCapture.image(
            runtime: runtime,
            displayedResource: displayedResource,
            frameIndex: frameIndex
        ) else {
            present(message: "Nothing has been rendered yet.")
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = writableTypes
        panel.nameFieldStringValue = "Frame.png"
        panel.canCreateDirectories = true
        panel.message = "Save the rendered frame."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let contentType = UTType(filenameExtension: url.pathExtension) ?? .png
        guard let data = FrameCapture.encode(image, as: contentType) else {
            present(message: "Can't write \(contentType.preferredFilenameExtension ?? contentType.identifier) images.")
            return
        }
        do {
            try data.write(to: url)
        } catch {
            NSApp.presentError(error)
        }
    }

    /// Puts the captured frame on the general pasteboard.
    static func copy(runtime: PhosphorRuntime, displayedResource: ResourceID?, frameIndex: UInt32) {
        guard let image = FrameCapture.image(
            runtime: runtime,
            displayedResource: displayedResource,
            frameIndex: frameIndex
        ) else {
            present(message: "Nothing has been rendered yet.")
            return
        }
        let size = NSSize(width: image.width, height: image.height)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([NSImage(cgImage: image, size: size)])
    }

    private static func present(message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
#endif
