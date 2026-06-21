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
        switch layoutMode {
        case .sideBySide:
            SideBySideEditorView(
                text: $text,
                parsed: parsed,
                assets: assets,
                onTextChange: onTextChange,
                isPaused: $isPaused,
                resetSignal: resetSignal,
                displayedResource: displayedResource
            )
        case .overlay:
            OverlayEditorView(
                text: $text,
                parsed: parsed,
                assets: assets,
                onTextChange: onTextChange,
                isPaused: $isPaused,
                resetSignal: resetSignal,
                displayedResource: displayedResource
            )
        }
    }
}

/// Side-by-side splitter: editable source on the left, live preview on the
/// right.
struct SideBySideEditorView: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    let onTextChange: () -> Void
    @Binding var isPaused: Bool
    let resetSignal: Int
    let displayedResource: ResourceID?

    var body: some View {
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
    }
}

/// Full-bleed preview with the code panel floating on top.
struct OverlayEditorView: View {
    @Binding var text: String
    let parsed: ParsedPhosphorSource
    let assets: [String: PhosphorAsset]
    let onTextChange: () -> Void
    @Binding var isPaused: Bool
    let resetSignal: Int
    let displayedResource: ResourceID?

    var body: some View {
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
