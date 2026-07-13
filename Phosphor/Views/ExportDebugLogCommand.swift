import CollaborationKitUI
import SwiftUI

/// File-menu item that exports the AI generation debug log. Reads the
/// action installed by ``CollaborationKitUI/View/collaborationDebugExport(store:model:defaultFilename:userInfo:)``
/// on the Generate panel; disabled when no conversation is active.
struct ExportDebugLogButton: View {
    @FocusedValue(\.exportDebugLog) private var exportDebugLog

    var body: some View {
        Button("Export Generation Debug Log…") {
            exportDebugLog?()
        }
        .disabled(exportDebugLog == nil)
    }
}
