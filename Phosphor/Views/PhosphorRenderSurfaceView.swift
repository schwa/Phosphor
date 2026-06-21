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
    let configuration: PhosphorConfiguration
    let viewSize: CGSize

    @Environment(EditorModel.self) private var model
    @Environment(PhosphorRuntime.self) private var runtime: PhosphorRuntime

    // Mouse state, in pixel coordinates (matching uniforms.resolution).
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero

    // Translates the renderer's free-running clock into the kernel time/frame a
    // shader sees, applying pause and reset.
    @State private var playbackClock = PlaybackClock()

    var body: some View {
        RenderView { context, drawableSize in
            PhosphorPipeline(
                runtime: runtime,
                uniforms: buildUniforms(context: context, drawableSize: drawableSize),
                userUniformValues: model.uniformValues,
                drawableSize: drawableSize,
                displayedResource: model.displayedResource
            )
            .onWorkloadEnter { _ in
                applyPlaybackSideEffects(context: context)
            }
        }
        .onFrameTimingChange { model.frameTimingStatistics = $0 }
        .onChange(of: model.isPaused) { _, newValue in
            if newValue {
                playbackClock.pause()
            } else {
                playbackClock.resume()
            }
        }
        .onChange(of: model.resetSignal) { _, _ in
            playbackClock.reset()
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
        let sample = playbackClock.kernelSample(wallClock: wallClock(from: context))
        return BuiltinUniforms(
            time: sample.time,
            timeDelta: sample.delta,
            frame: sample.frame,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mousePosition,
            mouseButtons: mouseButtons,
            mouseClickOrigin: mouseClickOrigin
        )
    }

    /// Per-frame state mutation triggered from `.onWorkloadEnter`.
    private func applyPlaybackSideEffects(context: RenderViewContext) {
        playbackClock.commit(wallClock: wallClock(from: context))
    }

    private func wallClock(from context: RenderViewContext) -> PlaybackClock.WallClock {
        PlaybackClock.WallClock(
            time: context.frameUniforms.time,
            frame: context.frameUniforms.index,
            delta: Float(context.frameUniforms.deltaTime)
        )
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
