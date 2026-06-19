import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Menu item that opens an untitled document of a specific `UTType` via
/// AppKit's `NSDocumentController`.
///
/// SwiftUI's `NewDocumentButton` is documented to be wired through
/// `DocumentGroupLaunchScene` and currently doesn't fire when placed in a
/// macOS `CommandGroup(replacing: .newItem)` (renders as enabled but
/// click is a no-op). This is the pragmatic AppKit-backed fallback until
/// SwiftUI catches up; swap back to `NewDocumentButton` when it works.
struct MyNewDocumentButton: View {
    let title: String
    let contentType: UTType

    var body: some View {
        Button(title) {
            openUntitledDocument()
        }
    }

    private func openUntitledDocument() {
        let controller = NSDocumentController.shared
        do {
            let document = try controller.makeUntitledDocument(ofType: contentType.identifier)
            controller.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
        } catch {
            NSApp.presentError(error)
        }
    }
}
