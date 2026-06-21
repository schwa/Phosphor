import PhosphorSupport
import SwiftUI

/// Shown in the preview pane when the source has no parsable front-matter.
struct NoFrontMatterView: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        ContentUnavailableView {
            Label("No front-matter", systemImage: "doc.text.magnifyingglass")
        } description: {
            if diagnostics.isEmpty {
                Text("This file has no /* phosphor:environment ... */ block.")
            } else {
                DiagnosticsListView(diagnostics: diagnostics)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

#Preview("Empty") {
    NoFrontMatterView(diagnostics: [])
        .frame(width: 400, height: 300)
}

#Preview("With diagnostics") {
    NoFrontMatterView(diagnostics: [.missingOutput("image")])
        .frame(width: 400, height: 300)
}
