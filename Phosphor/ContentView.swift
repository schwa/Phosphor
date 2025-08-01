import SwiftUI
import FoundationModels

struct ContentView: View {
    @State private var shaderCode = ""
    @State private var compiledShaderCode = ""
    @State private var compilationError: String?

    let shaderExamples = [
        "HelloTriangle",
        "Checkerboard",
        "RaymarchingSphere",
        "VoronoiCells",
        "Plasma",
        "Fire",
        "WaterRipples (Experimental)",
        "ReactionDiffusion (Experimental)",
        "Heart",
        "IterativeTrig",
        "FractalKaleidoscope",
        "TerrainRiver",
        "NoiseFlow",
        "FractalPlant",
        "Cityscape",
        "HSVRaymarch",
        "BrokenShader",
        "NeonLamp"
    ]

    var body: some View {
        HSplitView {
            MetalView(shaderSource: $compiledShaderCode, compilationError: $compilationError)
                .frame(minWidth: 400, minHeight: 600)

            // Right side - Text editor
            VStack(alignment: .leading) {


                DisclosureGroup("Generator") {
                    ShaderGeneratorView { generatedCode in
                        shaderCode = generatedCode
                    }
                }


                MetalTextEditor(text: $shaderCode)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                    .onChange(of: shaderCode) {
                        compileShader()
                    }

                if let error = compilationError {
                    ScrollView {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.system(.caption, design: .monospaced))
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 100)
                    .background(Color.red.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    )
                }
            }
        }
        .toolbar {
            Menu("Examples") {
                ForEach(shaderExamples, id: \.self) { example in
                    Button(example) {
                        loadShaderExample(example)
                    }
                }
            }
        }

        .onAppear {
            loadShaderCode()
        }
    }

    private func loadShaderCode() {
        loadShaderExample("HelloTriangle")
    }

    private func loadShaderExample(_ name: String) {
        // Remove the " (Experimental)" suffix if present
        let fileName = name.replacingOccurrences(of: " (Experimental)", with: "")

        if let url = Bundle.main.url(forResource: "\(fileName).metal", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            shaderCode = content
            compiledShaderCode = content
            compilationError = nil
        } else {
            shaderCode = "// Failed to load shader file: \(fileName)"
        }
    }

    private func compileShader() {
        // Clear any previous error
        compilationError = nil
        // Trigger compilation by updating the shader source
        compiledShaderCode = shaderCode
    }
}

