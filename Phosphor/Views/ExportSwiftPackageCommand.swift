import SwiftUI

/// Boxes the export action so the focused value isn't a bare closure (which
/// chokes the type-checker — see ``ExportDebugLogAction``).
struct ExportSwiftPackageAction {
    let run: () -> Void
}

extension FocusedValues {
    /// Action that exports the active document as a standalone Swift package.
    /// Published by the document views; `nil` when no document is focused.
    @Entry var exportSwiftPackage: ExportSwiftPackageAction?
}

/// File-menu item that exports the current shader as a Swift package. Disabled
/// when no document is focused.
struct ExportSwiftPackageButton: View {
    @FocusedValue(\.exportSwiftPackage) private var exportSwiftPackage: ExportSwiftPackageAction?

    var body: some View {
        Button("Export as Swift Package…") {
            exportSwiftPackage?.run()
        }
        .disabled(exportSwiftPackage == nil)
    }
}
