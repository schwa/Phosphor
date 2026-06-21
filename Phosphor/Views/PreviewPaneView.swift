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
    @Binding var uniformValues: [String: UniformValue]

    var body: some View {
        if parsed.hasFrontMatter {
            PhosphorView(
                parsed: parsed,
                assets: assets,
                isPaused: $isPaused,
                resetSignal: resetSignal,
                displayedResource: displayedResource,
                uniformValues: $uniformValues
            )
            .border(Color.pink)
        } else {
            NoFrontMatterView(diagnostics: parsed.diagnostics)
                .border(Color.purple)
        }
    }
}

#Preview("No front-matter") {
    PreviewPaneView(
        parsed: ParsedPhosphorSource(source: "// no front matter\n"),
        assets: [:],
        isPaused: .constant(false),
        resetSignal: 0,
        displayedResource: nil,
        uniformValues: .constant([:])
    )
    .frame(width: 400, height: 300)
}
