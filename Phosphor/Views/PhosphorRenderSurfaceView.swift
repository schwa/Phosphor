import Foundation
import MetalSprockets
import MetalSprocketsUI
import PhosphorCompile
import PhosphorMetalSprockets
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// The Metal render surface plus its mouse-tracking gestures.
///
/// Kept as its own view (rather than a computed property of
/// ``PhosphorRunningView``) so its greedy `DragGesture(minimumDistance: 0)`
/// is scoped to the surface and does not cover the panels layered above it.
///
/// Renders through ``PhosphorMetalSprockets/PhosphorMetalSprocketsView``, which
/// wraps PhosphorKit's raw-Metal `PhosphorRenderer` inside a MetalSprockets
/// `RenderView` (PhosphorKit itself is MetalSprockets-free).
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

    // Accumulator base for the zoom/rotate channels: the channel's normalized
    // value when the magnify/rotate gesture began, so deltas accumulate.
    @State private var zoomBase: Float = 0.5
    @State private var rotateBase: Float = 0.5

    private var gestureBindings: UniformGestureBinding.Bindings {
        UniformGestureBinding.bindings(for: configuration)
    }

    var body: some View {
        PhosphorMetalSprocketsView(
            runtime: runtime,
            userUniformValues: model.uniformValues,
            displayedResource: model.displayedResource,
            makeUniforms: { context, drawableSize in
                buildUniforms(context: context, drawableSize: drawableSize)
            },
            onFrameTiming: { model.frameTimingStatistics = $0 },
            onFrameTick: { context in
                applyPlaybackSideEffects(context: context)
            }
        )
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
                    applyDragChannels(at: value.location)
                }
                .onEnded { _ in
                    mouseButtons &= ~0b1
                }
        )
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    // magnification: 1.0 at rest; scale deltas around the base.
                    let delta = Float(value.magnification - 1.0)
                    apply(zoomBase + delta, to: .zoom)
                }
                .onEnded { _ in zoomBase = currentNormalized(for: .zoom) ?? zoomBase }
        )
        .gesture(
            RotateGesture()
                .onChanged { value in
                    // One full turn spans the uniform's range.
                    let delta = Float(value.rotation.radians / (2 * .pi))
                    apply(rotateBase + delta, to: .rotate)
                }
                .onEnded { _ in rotateBase = currentNormalized(for: .rotate) ?? rotateBase }
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

    /// Per-frame state mutation triggered once per frame from the host.
    private func applyPlaybackSideEffects(context: RenderViewContext) {
        playbackClock.commit(wallClock: wallClock(from: context))
    }

    // MARK: - Gesture-bound uniforms

    /// Drives the x / y channels from an absolute drag location, normalized to
    /// 0...1 over the view (y flipped so up == 1).
    private func applyDragChannels(at location: CGPoint) {
        let bindings = gestureBindings
        guard !bindings.isEmpty, viewSize.width > 0, viewSize.height > 0 else { return }
        let nx = Float(location.x / viewSize.width)
        let ny = 1 - Float(location.y / viewSize.height)
        var values = model.uniformValues
        UniformGestureBinding.apply(normalized: nx, channel: .x, bindings: bindings, into: &values)
        UniformGestureBinding.apply(normalized: ny, channel: .y, bindings: bindings, into: &values)
        model.uniformValues = values
    }

    /// Writes a normalized channel value into its bound uniform.
    private func apply(_ normalized: Float, to channel: UniformGesture) {
        let bindings = gestureBindings
        guard !bindings.isEmpty else { return }
        var values = model.uniformValues
        UniformGestureBinding.apply(normalized: normalized, channel: channel, bindings: bindings, into: &values)
        model.uniformValues = values
    }

    /// The current normalized (0...1) value of a channel's bound uniform, by
    /// inverting the slider-range mapping. Used to rebase zoom/rotate at
    /// gesture end. `nil` if nothing is bound.
    private func currentNormalized(for channel: UniformGesture) -> Float? {
        guard let bound = gestureBindings.uniform(for: channel),
              case .float(let value)? = model.uniformValues[bound.name] else { return nil }
        let span = bound.range.upperBound - bound.range.lowerBound
        guard span > 0 else { return 0 }
        return min(max((value - bound.range.lowerBound) / span, 0), 1)
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
