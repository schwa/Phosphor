import SwiftUI

/// Wraps the export action in a concrete type. Focused values that are bare
/// closures choke the type-checker, so we box the closure in a struct.
struct ExportDebugLogAction {
    let run: () -> Void
}

extension FocusedValues {
    /// Action that exports the current generation session's debug log.
    /// Published by ``GeneratePanel``; `nil` when no conversation exists.
    @Entry var exportDebugLog: ExportDebugLogAction?
}

/// File-menu item that exports the AI generation debug log. Disabled when no
/// conversation is active.
struct ExportDebugLogButton: View {
    @FocusedValue(\.exportDebugLog) private var exportDebugLog: ExportDebugLogAction?

    var body: some View {
        Button("Export Generation Debug Log…") {
            exportDebugLog?.run()
        }
        .disabled(exportDebugLog == nil)
    }
}
