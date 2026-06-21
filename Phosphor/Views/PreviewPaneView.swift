import PhosphorSupport
import SwiftUI

/// Right side of the document split: either the live render or a
/// no-front-matter placeholder.
struct PreviewPaneView: View {
    let parsed: ParsedPhosphorSource

    var body: some View {
        if parsed.hasFrontMatter {
            PhosphorRunningView(configuration: parsed.configuration)
        } else {
            NoFrontMatterView(diagnostics: parsed.diagnostics)
        }
    }
}

#Preview("No front-matter") {
    PreviewPaneView(parsed: ParsedPhosphorSource(source: "// no front matter\n"))
        .frame(width: 400, height: 300)
}
