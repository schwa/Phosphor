import SwiftUI
import MetalKit

struct BareMetalView: NSViewRepresentable {

    typealias DrawableSizeWillChangeCallback = (CGSize) -> Void
    typealias DrawCallback = (MTLRenderPassDescriptor, MTLDrawable) -> Void

    class Coordinator: NSObject, MTKViewDelegate {
        var drawableSizeWillChange: DrawableSizeWillChangeCallback?
        var draw: DrawCallback?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            drawableSizeWillChange?(size)
        }
        func draw(in view: MTKView) {
            draw?(view.currentRenderPassDescriptor!, view.currentDrawable!)
        }
    }

    let device: MTLDevice
    let drawableSizeWillChange: DrawableSizeWillChangeCallback?
    let draw: DrawCallback?

    init(device: MTLDevice, drawableSizeWillChange: DrawableSizeWillChangeCallback?, draw: DrawCallback?) {
        self.device = device
        self.drawableSizeWillChange = drawableSizeWillChange
        self.draw = draw
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = device
        mtkView.delegate = context.coordinator
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.drawableSizeWillChange = drawableSizeWillChange
        context.coordinator.draw = draw
    }
}
