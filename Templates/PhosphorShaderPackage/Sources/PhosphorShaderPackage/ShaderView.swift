import PhosphorRuntime
import SwiftUI

/// A self-contained view that renders the bundled Phosphor shader.
///
/// The shader lives at `Resources/Shader.phosphor` and is loaded by name from
/// this package's resource bundle. Drop this package into your app (or just
/// copy `ShaderView.swift` + `Shader.phosphor`) and embed `ShaderView()`
/// wherever you want the animation.
public struct ShaderView: View {
    public init() {}

    public var body: some View {
        PhosphorView(named: "Shader", bundle: .module)
    }
}

#Preview {
    ShaderView()
        .frame(width: 320, height: 240)
}
