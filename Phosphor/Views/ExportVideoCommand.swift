import SwiftUI

/// Boxes the export action so the focused value isn't a bare closure (which
/// chokes the type-checker — see ``ExportSwiftPackageAction``).
struct ExportVideoAction {
    let run: () -> Void
}

extension FocusedValues {
    /// Opens the video-export sheet for the focused document. `nil` when no
    /// document is focused.
    @Entry var exportVideo: ExportVideoAction?
}

/// File-menu item that exports the shader as a movie.
struct ExportVideoButton: View {
    @FocusedValue(\.exportVideo) private var exportVideo: ExportVideoAction?

    var body: some View {
        Button("Export Video…") {
            exportVideo?.run()
        }
        .disabled(exportVideo == nil)
    }
}
