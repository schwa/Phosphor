import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    @Binding var shaderSource: String
    @Binding var compilationError: String?
    
    func makeCoordinator() -> Renderer {
        Renderer()
    }
    
    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.delegate = context.coordinator
        mtkView.device = context.coordinator.device
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        mtkView.drawableSize = mtkView.frame.size
        return mtkView
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {
        if !shaderSource.isEmpty {
            context.coordinator.updateShaderSource(shaderSource) { error in
                Task {
                    await MainActor.run {
                        compilationError = error
                    }
                }
            }
        }
    }
}
