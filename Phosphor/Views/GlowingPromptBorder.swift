import SwiftUI

/// A soft, multicolor gradient border reminiscent of Xcode's Coding
/// Intelligence prompt field. The gradient slowly rotates; when `active` it
/// becomes brighter/thicker to signal focus.
///
/// Cross-platform (no AppKit): uses SwiftUI semantic colors and an
/// `AngularGradient` so it adapts to light/dark mode.
struct GlowingPromptBorder: ViewModifier {
    var cornerRadius: CGFloat = 16
    var active: Bool = false

    @State private var rotation: Angle = .zero

    private var palette: [Color] {
        [.pink, .purple, .blue, .teal, .green, .orange, .pink]
    }

    func body(content: Content) -> some View {
        content
            .background(.background, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border, lineWidth: active ? 2 : 1)
            }
            .shadow(color: glowColor.opacity(active ? 0.35 : 0), radius: active ? 10 : 0)
            .animation(.easeInOut(duration: 0.25), value: active)
            .onAppear {
                withAnimation(.linear(duration: 12).repeatForever(autoreverses: false)) {
                    rotation = .degrees(360)
                }
            }
    }

    private var border: AngularGradient {
        AngularGradient(
            colors: active ? palette : palette.map { $0.opacity(0.45) },
            center: .center,
            angle: rotation
        )
    }

    private var glowColor: Color { .purple }
}

extension View {
    /// Wraps the view in an Xcode-style glowing multicolor prompt border.
    func glowingPromptBorder(cornerRadius: CGFloat = 16, active: Bool = false) -> some View {
        modifier(GlowingPromptBorder(cornerRadius: cornerRadius, active: active))
    }
}
