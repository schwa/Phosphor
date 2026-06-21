import PhosphorSupport
import SwiftUI

/// Translucent panel listing every declared user-uniform with live controls.
/// Hides itself when the environment declares no uniforms or the panel is
/// toggled off.
struct UniformsPanelView: View {
    let uniforms: [UniformDecl]
    let showPanel: Bool
    @Binding var uniformValues: [String: UniformValue]

    var body: some View {
        if !uniforms.isEmpty, showPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text("Uniforms")
                    .font(.caption)
                    .bold()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thickMaterial)

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(uniforms, id: \.name) { uniform in
                        UniformControl(
                            uniform: uniform,
                            value: Binding(
                                get: { uniformValues[uniform.name] ?? uniform.defaultValue },
                                set: { uniformValues[uniform.name] = $0 }
                            )
                        )
                    }
                }
                .padding(8)
                .background(.regularMaterial)
            }
            .clipShape(.rect(cornerRadius: 6))
            .frame(maxWidth: 320)
            // Keep the panel inside the window's safe area (toolbar, rounded
            // corners, etc.) and add a little breathing room from the edge.
            .padding(8)
            .safeAreaPadding()
        }
    }
}

#Preview("Populated") {
    UniformsPanelView(
        uniforms: [
            UniformDecl(name: "speed", kind: .float, defaultValue: .float(1.0), ui: .slider(min: 0, max: 2)),
            UniformDecl(name: "scale", kind: .float, defaultValue: .float(0.5), ui: .slider(min: 0, max: 1))
        ],
        showPanel: true,
        uniformValues: .constant([:])
    )
    .frame(width: 480, height: 320)
    .background(.black)
}

#Preview("Empty") {
    UniformsPanelView(uniforms: [], showPanel: true, uniformValues: .constant([:]))
        .frame(width: 480, height: 320)
        .background(.black)
}
