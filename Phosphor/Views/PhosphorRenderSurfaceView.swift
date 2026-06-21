import Foundation
import MetalSprockets
import MetalSprocketsUI
import PhosphorSupport
import SwiftUI

/// The Metal render surface plus its mouse-tracking gestures.
///
/// Kept as its own view (rather than a computed property of
/// ``PhosphorRunningView``) so its greedy `DragGesture(minimumDistance: 0)`
/// is scoped to the surface and does not cover the panels layered above it.
struct PhosphorRenderSurfaceView: View {
    let runtime: PhosphorRuntime
    let environment: PhosphorEnvironment
    let uniformValues: [String: UniformValue]
    let displayedResource: ResourceID?
    let isPausedExternally: Binding<Bool>?
    let resetSignal: Int
    let viewSize: CGSize

    @Binding var mousePosition: SIMD2<Float>
    @Binding var mouseButtons: UInt32
    @Binding var mouseClickOrigin: SIMD2<Float>
    @Binding var timeBase: Float
    @Binding var frameBase: UInt32
    @Binding var pausedSnapshot: (time: Float, frame: Float)?
    @Binding var capturePauseSnapshot: Bool
    @Binding var rebaseRequested: Bool

    var body: some View {
        RenderView { context, drawableSize in
            PhosphorPipeline(
                runtime: runtime,
                uniforms: buildUniforms(context: context, drawableSize: drawableSize),
                userUniformValues: uniformValues,
                drawableSize: drawableSize,
                displayedResource: displayedResource
            )
            .onWorkloadEnter { _ in
                applyPlaybackSideEffects(context: context)
            }
        }
        .onChange(of: isPausedExternally?.wrappedValue ?? false) { _, newValue in
            if newValue {
                capturePauseSnapshot = true
            } else {
                pausedSnapshot = nil
                rebaseRequested = true
            }
        }
        .onChange(of: resetSignal) { _, _ in
            rebaseRequested = true
            pausedSnapshot = nil
            capturePauseSnapshot = false
            runtime.signalReset()
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                mousePosition = pixelCoordinate(from: point)
            case .ended:
                break
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    mousePosition = pixelCoordinate(from: value.location)
                    if mouseButtons & 0b1 == 0 {
                        // First frame of the press: record click origin.
                        mouseClickOrigin = pixelCoordinate(from: value.startLocation)
                    }
                    mouseButtons |= 0b1
                }
                .onEnded { _ in
                    mouseButtons &= ~0b1
                }
        )
    }

    /// Builds the per-frame `BuiltinUniforms`, applying pause/rebase.
    private func buildUniforms(context: RenderViewContext, drawableSize: CGSize) -> BuiltinUniforms {
        let kernelTime: Float
        let kernelFrame: Float
        let kernelDelta: Float
        if let paused = pausedSnapshot {
            kernelTime = paused.time
            kernelFrame = paused.frame
            kernelDelta = 0
        } else {
            kernelTime = context.frameUniforms.time - timeBase
            kernelFrame = Float(context.frameUniforms.index &- frameBase)
            kernelDelta = Float(context.frameUniforms.deltaTime)
        }
        return BuiltinUniforms(
            time: kernelTime,
            timeDelta: kernelDelta,
            frame: kernelFrame,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mousePosition,
            mouseButtons: mouseButtons,
            mouseClickOrigin: mouseClickOrigin
        )
    }

    /// Per-frame state mutation triggered from `.onWorkloadEnter`.
    private func applyPlaybackSideEffects(context: RenderViewContext) {
        if capturePauseSnapshot {
            let liveTime = context.frameUniforms.time - timeBase
            let liveFrame = Float(context.frameUniforms.index &- frameBase)
            pausedSnapshot = (time: liveTime, frame: liveFrame)
            capturePauseSnapshot = false
        }
        if rebaseRequested {
            timeBase = context.frameUniforms.time
            frameBase = context.frameUniforms.index
            rebaseRequested = false
        }
    }

    /// Converts a point in the view's coordinate space to pixel coordinates
    /// matching `uniforms.resolution`.
    private func pixelCoordinate(from point: CGPoint) -> SIMD2<Float> {
        let drawableSize = runtime.currentDrawableSize
        guard viewSize.width > 0, viewSize.height > 0,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return SIMD2<Float>(Float(point.x), Float(point.y))
        }
        let scaleX = Float(drawableSize.width / viewSize.width)
        let scaleY = Float(drawableSize.height / viewSize.height)
        return SIMD2<Float>(Float(point.x) * scaleX, Float(point.y) * scaleY)
    }
}
