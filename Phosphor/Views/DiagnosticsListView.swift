import PhosphorSupport
import SwiftUI

/// Vertical list of parse diagnostics, monospaced and text-selectable.
struct DiagnosticsListView: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Failed to parse front-matter:")
            ForEach(diagnostics.enumerated(), id: \.offset) { _, diagnostic in
                Text(verbatim: String(describing: diagnostic))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
    }
}

#Preview("Diagnostics list") {
    DiagnosticsListView(diagnostics: [
        .missingOutput("image"),
        .duplicatePass("render")
    ])
    .frame(width: 400)
}
