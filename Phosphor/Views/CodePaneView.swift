import PhosphorCompile
import PhosphorEditorSupport
import PhosphorGeneration
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// Left side of the document split: a tabbed source view with the editable
/// Metal shader (tab 1) and the read-only generated `Phosphor.h` prelude
/// (tab 2).
struct CodePaneView: View {
    @Binding var text: String
    let onTextChange: () -> Void
    /// Configuration used to render the `Phosphor.h` prelude tab.
    let configuration: PhosphorConfiguration
    /// When true (the default), paints an opaque text-background color
    /// behind the editor. Overlay layout passes `false` so the underlying
    /// preview shows through.
    var opaque: Bool = true
    /// Optional explicit palette. When nil, picks ``SyntaxPalette/dark``
    /// or ``SyntaxPalette/default`` based on the current color scheme.
    var palette: SyntaxPalette?

    private enum SourceTab: Hashable {
        case shader
        case header
    }

    @State private var selectedTab: SourceTab = .shader
    @Environment(\.colorScheme) private var colorScheme

    private var resolvedPalette: SyntaxPalette {
        if let palette { return palette }
        return colorScheme == .dark ? .dark : .default
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Source", selection: $selectedTab) {
                Text("Shader.metal").tag(SourceTab.shader)
                Text("Phosphor.h").tag(SourceTab.header)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .center)

            switch selectedTab {
            case .shader:
                shaderTab
            case .header:
                headerTab
            }
        }
    }

    private var shaderTab: some View {
        MetalSourceView(text: $text, palette: resolvedPalette)
            .background(opaque ? Self.editorBackground : .clear)
            .onChange(of: text) { _, _ in
                onTextChange()
            }
    }

    private var headerTab: some View {
        MetalSourceView(text: PhosphorHeader.source(for: configuration), palette: resolvedPalette)
            .background(opaque ? Self.editorBackground : .clear)
    }

    /// Platform-appropriate opaque background for the code surface.
    private static var editorBackground: Color {
        #if os(macOS)
        Color(.textBackgroundColor)
        #else
        Color(.systemBackground)
        #endif
    }
}

#Preview("Code pane") {
    CodePaneView(
        text: .constant("kernel void image() {}\n"),
        onTextChange: {},
        configuration: PhosphorConfiguration(output: "image")
    )
    .frame(width: 400, height: 300)
}
