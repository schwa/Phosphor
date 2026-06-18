import SwiftUI

/// Renders a single SwiftUI control for one ``UniformDecl``.
///
/// Uses fully-qualified `SwiftUI.Binding<T>` everywhere because we have a
/// `Binding` model type elsewhere (channel input binding) that shadows the
/// SwiftUI one inside this module.
///
/// The shape of the control is chosen by ``UniformDecl/ui``:
/// - `.slider(min, max)`: `Slider` for `.float` / `.int`.
/// - `.color`: `ColorPicker` for `.color` / `.float4`.
/// - `.toggle`: `Toggle` for `.bool`.
/// - `.vector`: a row of sliders, one per component.
/// - `nil`: a sensible default per kind.
struct UniformControl: View {
    let uniform: UniformDecl
    let value: SwiftUI.Binding<UniformValue>

    var body: some View {
        HStack {
            Text(uniform.name)
                .font(.system(.caption, design: .monospaced))
                .frame(minWidth: 80, alignment: .leading)
            controlBody
        }
    }

    @ViewBuilder
    private var controlBody: some View {
        switch (uniform.ui, value.wrappedValue) {
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
            vectorRow(values: [vector.x, vector.y]) { newValues in
                value.wrappedValue = .float2(.init(newValues[0], newValues[1]))
            }
        case (.vector, .float3(let vector)):
            vectorRow(values: [vector.x, vector.y, vector.z]) { newValues in
                value.wrappedValue = .float3(.init(newValues[0], newValues[1], newValues[2]))
            }
        case (.vector, .float4(let vector)):
            vectorRow(values: [vector.x, vector.y, vector.z, vector.w]) { newValues in
                value.wrappedValue = .float4(.init(newValues[0], newValues[1], newValues[2], newValues[3]))
            }
        default:
            Text("(unsupported)").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func vectorRow(values: [Float], setter: @escaping ([Float]) -> Void) -> some View {
        HStack(spacing: 4) {
            ForEach(values.indices, id: \.self) { index in
                Slider(
                    value: SwiftUI.Binding<Double>(
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

    // MARK: - Binding adapters

    private func floatBinding(_ initial: Float) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding<Double>(
            get: { Double(initial) },
            set: { newValue in value.wrappedValue = .float(Float(newValue)) }
        )
    }

    private func intBinding(_ initial: Int32) -> SwiftUI.Binding<Double> {
        SwiftUI.Binding<Double>(
            get: { Double(initial) },
            set: { newValue in value.wrappedValue = .int(Int32(newValue.rounded())) }
        )
    }

    private func boolBinding(_ initial: Bool) -> SwiftUI.Binding<Bool> {
        SwiftUI.Binding<Bool>(
            get: { initial },
            set: { value.wrappedValue = .bool($0) }
        )
    }

    private func colorBinding(_ rgba: SIMD4<Float>) -> SwiftUI.Binding<Color> {
        SwiftUI.Binding<Color>(
            get: { Color(red: Double(rgba.x), green: Double(rgba.y), blue: Double(rgba.z), opacity: Double(rgba.w)) },
            set: { newColor in
                let resolved = newColor.resolve(in: .init())
                value.wrappedValue = .float4(.init(resolved.red, resolved.green, resolved.blue, resolved.opacity))
            }
        )
    }
}
