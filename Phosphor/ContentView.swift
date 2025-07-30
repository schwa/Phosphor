//
//  ContentView.swift
//  Phosphor
//
//  Created by Jonathan Wight on 7/30/25.
//

import SwiftUI

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
        "BrokenShader"
    ]
    
    var body: some View {
        HSplitView {
            // Left side - Metal view
            MetalView(shaderSource: $compiledShaderCode, compilationError: $compilationError)
                .frame(minWidth: 400, minHeight: 600)
            
            // Right side - Text editor
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Shader Editor")
                        .font(.headline)
                    
                    Spacer()
                    
                    Menu("Examples") {
                        ForEach(shaderExamples, id: \.self) { example in
                            Button(example) {
                                loadShaderExample(example)
                            }
                        }
                    }
                    
                    Button("Compile") {
                        compileShader()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                
                TextEditor(text: $shaderCode)
                    .font(.system(.body, design: .monospaced))
                    .padding(4)
                
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
            .frame(minWidth: 400, minHeight: 600)
        }
        .frame(minWidth: 800, minHeight: 600)
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
           let content = try? String(contentsOf: url) {
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

#Preview {
    ContentView()
}
