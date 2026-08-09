import SwiftUI

/// Boxes the frame-capture actions so the focused value isn't a bare closure
/// (which chokes the type-checker — see ``ExportSwiftPackageAction``).
struct ExportFrameAction {
    let save: () -> Void
    let copy: () -> Void
}

extension FocusedValues {
    /// Actions that capture the currently rendered frame. Published by the
    /// running view; `nil` when nothing is rendering.
    @Entry var exportFrame: ExportFrameAction?
}

/// File-menu items that save or copy the rendered frame. Disabled when no
/// document is rendering.
struct ExportFrameButtons: View {
    @FocusedValue(\.exportFrame) private var exportFrame: ExportFrameAction?

    var body: some View {
        Button("Export Frame as Image…") {
            exportFrame?.save()
        }
        .disabled(exportFrame == nil)

        Button("Copy Frame") {
            exportFrame?.copy()
        }
        .keyboardShortcut("c", modifiers: [.command, .shift])
        .disabled(exportFrame == nil)
    }
}
