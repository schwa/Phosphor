import PhosphorSupport
import SwiftUI

/// Right side of the document split: either the live render or a
/// no-front-matter placeholder.
struct PreviewPaneView: View {
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    @Binding var isPaused: Bool
    let resetSignal: Int
    let displayedResource: ResourceID?

    var body: some View {
        if let view = PhosphorView(
            parsed: parsed,
            assets: assets,
            isPaused: $isPaused,
            resetSignal: resetSignal,
            displayedResource: displayedResource
        ) {
            view
        } else {
            NoFrontMatterView(diagnostics: parsed.diagnostics)
        }
    }
}

#Preview("No front-matter") {
    PreviewPaneView(
        parsed: ParsedPhosphorSource(source: "// no front matter\n"),
        assets: [:],
        isPaused: .constant(false),
        resetSignal: 0,
        displayedResource: nil
    )
    .frame(width: 400, height: 300)
}
