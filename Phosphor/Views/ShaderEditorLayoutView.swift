import MetalSprocketsUI
import PhosphorCompile
import PhosphorEditorSupport
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// User-facing layout mode for the editor. Cycles through a horizontal
/// splitter (default), a vertical splitter, and code overlaid on a
/// full-bleed preview.
enum LayoutMode: String, CaseIterable, Identifiable {
    case horizontal
    case vertical
    case overlay
    case previewOnly

    var id: Self { self }

    /// SF Symbol shown for this layout.
    var systemImage: String {
        switch self {
        case .horizontal: "rectangle.split.2x1"
        case .vertical: "rectangle.split.1x2"
        case .overlay: "rectangle.on.rectangle"
        case .previewOnly: "rectangle"
        }
    }

    /// Human-readable name for this layout.
    var title: String {
        switch self {
        case .horizontal: "Horizontal Split"
        case .vertical: "Vertical Split"
        case .overlay: "Overlay"
        case .previewOnly: "Preview Only"
        }
    }
}

/// Arranges the code pane and preview pane according to the active
/// ``LayoutMode``: side-by-side splitter or code overlaid on a full-bleed
/// preview.
struct ShaderEditorLayoutView: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let onTextChange: () -> Void

    @SceneStorage("phosphor.ui.layoutMode") private var layoutMode: LayoutMode = .horizontal
    @SceneStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @SceneStorage("phosphor.ui.showFrameTiming") private var showFrameTiming: Bool = true
    @Environment(EditorModel.self) private var model
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

    var body: some View {
        @Bindable var model = model
        #if os(macOS)
        switch layoutMode {
        case .horizontal:
            HSplitView {
                CodePaneView(text: $text, onTextChange: onTextChange, configuration: parsed.configuration)
                    .frame(minWidth: 300)
                preview
                    .frame(minWidth: 300)
            }

        case .vertical:
            VSplitView {
                CodePaneView(text: $text, onTextChange: onTextChange, configuration: parsed.configuration)
                    .frame(minHeight: 200)
                preview
                    .frame(minHeight: 200)
            }

        case .overlay:
            overlayLayout

        case .previewOnly:
            previewOnlyLayout
        }
        #else
        // iOS has no split views; use the overlaid (ZStack) layout, or a
        // full-bleed preview for the preview-only mode.
        switch layoutMode {
        case .previewOnly:
            previewOnlyLayout
        default:
            overlayLayout
        }
        #endif
    }

    /// Full-bleed preview with the standard overlays, no code pane. Like the
    /// overlay layout (extends under the toolbar / inspector) minus the editor.
    private var previewOnlyLayout: some View {
        @Bindable var model = model
        return PreviewPaneView(parsed: parsed)
            .ignoresSafeArea()
            .modifier(PreviewOverlays(
                diagnostics: parsed.diagnostics + runtime.diagnostics,
                frameTiming: frameTiming,
                uniforms: parsed.configuration.uniforms,
                showUniformsPanel: showUniformsPanel,
                uniformValues: $model.uniformValues
            ))
    }

    /// Code overlaid on a full-bleed preview (ZStack). The only layout on iOS.
    private var overlayLayout: some View {
        @Bindable var model = model
        return ZStack {
            PreviewPaneView(parsed: parsed)
                .ignoresSafeArea()

            CodePaneView(text: $text, onTextChange: onTextChange, configuration: parsed.configuration, opaque: false, palette: .darkWithBackdrop)
                .padding(16)
        }
        .modifier(PreviewOverlays(
            diagnostics: parsed.diagnostics + runtime.diagnostics,
            frameTiming: frameTiming,
            uniforms: parsed.configuration.uniforms,
            showUniformsPanel: showUniformsPanel,
            uniformValues: $model.uniformValues
        ))
    }

    /// Preview pane with the standard diagnostics / frame-timing / uniforms
    /// overlays, shared by the split and preview-only layouts.
    private var preview: some View {
        @Bindable var model = model
        return PreviewPaneView(parsed: parsed)
            .modifier(PreviewOverlays(
                diagnostics: parsed.diagnostics + runtime.diagnostics,
                frameTiming: frameTiming,
                uniforms: parsed.configuration.uniforms,
                showUniformsPanel: showUniformsPanel,
                uniformValues: $model.uniformValues
            ))
    }

    @ViewBuilder
    private var frameTiming: some View {
        if showFrameTiming, let statistics = model.frameTimingStatistics {
            FrameTimingView(statistics: statistics, options: [.fps, .frameTime, .gpuTime])
                .allowsHitTesting(false)
        }
    }
}

/// Standard overlays painted over the preview surface in every layout:
/// diagnostics (top-leading), frame timing (top-trailing), and the
/// uniforms panel (bottom).
private struct PreviewOverlays<FrameTiming: View>: ViewModifier {
    let diagnostics: [PhosphorDiagnostic]
    let frameTiming: FrameTiming
    let uniforms: [UniformDecl]
    let showUniformsPanel: Bool
    @Binding var uniformValues: [String: UniformValue]

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                DiagnosticsView(diagnostics: diagnostics)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                frameTiming
            }
            .overlay(alignment: .bottom) {
                UniformsPanelView(
                    uniforms: uniforms,
                    showPanel: showUniformsPanel,
                    uniformValues: $uniformValues
                )
            }
    }
}
