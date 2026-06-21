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
    @Binding var uniformValues: [String: UniformValue]
    let showUniformsPanel: Bool
    let frontMatterDiagnostics: [PhosphorDiagnostic]

    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

    var body: some View {
        switch layoutMode {
        case .sideBySide:
            HSplitView {
                CodePaneView(text: $text, onTextChange: onTextChange)
                    .frame(minWidth: 300)
                    .border(Color.blue)
                PreviewPaneView(
                    parsed: parsed,
                    assets: assets,
                    isPaused: $isPaused,
                    resetSignal: resetSignal,
                    displayedResource: displayedResource,
                    uniformValues: $uniformValues
                )
                .frame(minWidth: 300)
                .border(Color.green)
                .overlay(alignment: .topLeading) {
                    DiagnosticsView(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    UniformsPanelView(
                        uniforms: parsed.configuration.uniforms,
                        showPanel: showUniformsPanel,
                        uniformValues: $uniformValues
                    )
                }
            }
            .border(Color.red)
        case .overlay:
            ZStack {
                PreviewPaneView(
                    parsed: parsed,
                    assets: assets,
                    isPaused: $isPaused,
                    resetSignal: resetSignal,
                    displayedResource: displayedResource,
                    uniformValues: $uniformValues
                )
                .ignoresSafeArea()

                CodePaneView(text: $text, onTextChange: onTextChange, opaque: false, palette: .darkWithBackdrop)
                    .padding(16)
            }
            .overlay(alignment: .topLeading) {
                DiagnosticsView(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                UniformsPanelView(
                    uniforms: parsed.configuration.uniforms,
                    showPanel: showUniformsPanel,
                    uniformValues: $uniformValues
                )
            }
        }
    }
}

