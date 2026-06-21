import PhosphorSupport
import SwiftUI

/// User-facing layout mode for the editor: side-by-side splitter
/// (default) or code panel overlaid on a full-bleed preview.
enum LayoutMode: String, CaseIterable {
    case sideBySide
    case overlay

    mutating func toggle() {
        self = self == .sideBySide ? .overlay : .sideBySide
    }
}

/// Arranges the code pane and preview pane according to the active
/// ``LayoutMode``: side-by-side splitter or code overlaid on a full-bleed
/// preview.
struct ShaderEditorLayoutView: View {
    let layoutMode: LayoutMode
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    let onTextChange: () -> Void
    @Binding var isPaused: Bool
    let resetSignal: Int
    let displayedResource: ResourceID?

    var body: some View {
        Group {
            switch layoutMode {
            case .sideBySide:
                HSplitView {
                    CodePaneView(text: $text, onTextChange: onTextChange)
                    PreviewPaneView(
                        parsed: parsed,
                        assets: assets,
                        isPaused: $isPaused,
                        resetSignal: resetSignal,
                        displayedResource: displayedResource
                    )
                }
            case .overlay:
                ZStack {
                    PreviewPaneView(
                        parsed: parsed,
                        assets: assets,
                        isPaused: $isPaused,
                        resetSignal: resetSignal,
                        displayedResource: displayedResource
                    )
                    .ignoresSafeArea()

                    CodePaneView(text: $text, onTextChange: onTextChange, opaque: false, palette: .darkWithBackdrop)
                        .padding(16)
                }
            }
        }
//        .overlay {
//            DiagnosticsView(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
//                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
//                .allowsHitTesting(false)
//
//        }
//        .overlay {
//            UniformsPanelView(
//                uniforms: configuration.uniforms,
//                showPanel: showUniformsPanel,
//                uniformValues: $uniformValues
//            )
//        }
    }
}

