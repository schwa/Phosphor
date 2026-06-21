import PhosphorSupport
import SwiftUI

/// Left side of the document split: the editable Metal source.
struct CodePaneView: View {
    @Binding var text: String
    let onTextChange: () -> Void
    /// When true (the default), paints an opaque text-background color
    /// behind the editor. Overlay layout passes `false` so the underlying
    /// preview shows through.
    var opaque: Bool = true
    /// Optional explicit palette. When nil, picks ``SyntaxPalette/dark``
    /// or ``SyntaxPalette/default`` based on the current color scheme.
    var palette: SyntaxPalette?

    @Environment(\.colorScheme) private var colorScheme

    private var resolvedPalette: SyntaxPalette {
        if let palette { return palette }
        return colorScheme == .dark ? .dark : .default
    }

    var body: some View {
        MetalSourceView(text: $text, palette: resolvedPalette)
            .background(opaque ? Color(.textBackgroundColor) : .clear)
            .onChange(of: text) { _, _ in
                onTextChange()
            }
    }
}

#Preview("Code pane") {
    CodePaneView(text: .constant("kernel void image() {}\n"), onTextChange: {})
        .frame(width: 400, height: 300)
}
