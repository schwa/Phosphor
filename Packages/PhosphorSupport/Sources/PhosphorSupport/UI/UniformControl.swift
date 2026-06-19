import SwiftUI

/// Renders a single SwiftUI control for one ``UniformDecl``.
///
/// The shape of the control is chosen by ``UniformDecl/ui``:
/// - `.slider(min, max)`: `Slider` for `.float` / `.int`.
/// - `.color`: `ColorPicker` for `.color` / `.float4`.
/// - `.toggle`: `Toggle` for `.bool`.
/// - `.vector`: a row of sliders, one per component.
/// - `nil`: a sensible default per kind.
struct UniformControl: View {
    let uniform: UniformDecl
    @Binding var value: UniformValue

    var body: some View {
        HStack {
            Text(uniform.name)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 80, alignment: .leading)
            UniformControlBody(uniform: uniform, value: $value)
        }
    }
}

/// Inner control row for a single uniform. Dispatches on `(ui, value)` to
/// pick the right Slider / Toggle / ColorPicker / vector row.
private struct UniformControlBody: View {
    let uniform: UniformDecl
    @Binding var value: UniformValue

    var body: some View {
        switch (uniform.ui, value) {
        case (.slider(let lo, let hi), .float(let scalar)):
            Slider(value: floatBinding(scalar), in: Double(lo)...Double(hi))
            Text(String(format: "%.2f", scalar))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .trailing)

        case (.slider(let lo, let hi), .int(let scalar)):
            Slider(value: intBinding(scalar), in: Double(lo)...Double(hi), step: 1)
            Text("\(scalar)")
                .font(.system(.caption, design: .monospaced))
                .frame(width: 50, alignment: .trailing)

        case (.color, .float4(let rgba)):
            ColorPicker("", selection: colorBinding(rgba))
                .labelsHidden()

        case (.toggle, .bool(let flag)):
            Toggle("", isOn: boolBinding(flag))
                .labelsHidden()

        case (.vector, .float2(let vector)):
            VectorSliderRow(values: [vector.x, vector.y]) { new in
                value = .float2(.init(new[0], new[1]))
            }

        case (.vector, .float3(let vector)):
            VectorSliderRow(values: [vector.x, vector.y, vector.z]) { new in
                value = .float3(.init(new[0], new[1], new[2]))
            }

        case (.vector, .float4(let vector)):
            VectorSliderRow(values: [vector.x, vector.y, vector.z, vector.w]) { new in
                value = .float4(.init(new[0], new[1], new[2], new[3]))
            }

        default:
            Text("(unsupported)").foregroundStyle(.secondary)
        }
    }

    // MARK: - Binding adapters

    private func floatBinding(_ initial: Float) -> Binding<Double> {
        Binding(
            get: { Double(initial) },
            set: { newValue in value = .float(Float(newValue)) }
        )
    }

    private func intBinding(_ initial: Int32) -> Binding<Double> {
        Binding(
            get: { Double(initial) },
            set: { newValue in value = .int(Int32(newValue.rounded())) }
        )
    }

    private func boolBinding(_ initial: Bool) -> Binding<Bool> {
        Binding(
            get: { initial },
            set: { value = .bool($0) }
        )
    }

    private func colorBinding(_ rgba: SIMD4<Float>) -> Binding<Color> {
        Binding(
            get: { Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w)) },
            set: { newColor in
                let resolved = newColor.resolve(in: .init())
                value = .float4(.init(resolved.red, resolved.green, resolved.blue, resolved.opacity))
            }
        )
    }
}

/// Row of unit-range sliders, one per vector component. Used for
/// `.vector`-style uniforms over `float2/3/4`.
private struct VectorSliderRow: View {
    let values: [Float]
    let setter: ([Float]) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                Slider(
                    value: Binding(
                        get: { Double(values[index]) },
                        set: { newValue in
                            var updated = values
                            updated[index] = Float(newValue)
                            setter(updated)
                        }
                    ),
                    in: 0...1
                )
            }
        }
    }
}

// MARK: - Previews

#Preview("Float slider") {
    StatefulPreviewWrapper(UniformValue.float(0.5)) { binding in
        UniformControl(
            uniform: UniformDecl(name: "intensity", kind: .float, defaultValue: .float(0.5), ui: .slider(min: 0, max: 1)),
            value: binding
        )
        .padding()
        .frame(width: 320)
    }
}

#Preview("Color picker") {
    StatefulPreviewWrapper(UniformValue.float4(.init(0.6, 0.8, 1.0, 1.0))) { binding in
        UniformControl(
            uniform: UniformDecl(name: "tint", kind: .color, defaultValue: .float4(.init(0.6, 0.8, 1.0, 1.0)), ui: .color),
            value: binding
        )
        .padding()
        .frame(width: 320)
    }
}

#Preview("Toggle") {
    StatefulPreviewWrapper(UniformValue.bool(true)) { binding in
        UniformControl(
            uniform: UniformDecl(name: "showGrid", kind: .bool, defaultValue: .bool(true), ui: .toggle),
            value: binding
        )
        .padding()
        .frame(width: 320)
    }
}

#Preview("Vector (float3)") {
    StatefulPreviewWrapper(UniformValue.float3(.init(0.2, 0.5, 0.8))) { binding in
        UniformControl(
            uniform: UniformDecl(name: "direction", kind: .float3, defaultValue: .float3(.init(0.2, 0.5, 0.8)), ui: .vector),
            value: binding
        )
        .padding()
        .frame(width: 320)
    }
}

/// Wraps a piece of state to give previews a mutable Binding without
/// requiring an enclosing model. Standard SwiftUI preview idiom.
private struct StatefulPreviewWrapper<Value, Content: View>: View {
    @State private var value: Value
    let content: (Binding<Value>) -> Content

    init(_ initial: Value, @ViewBuilder content: @escaping (Binding<Value>) -> Content) {
        self._value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}
