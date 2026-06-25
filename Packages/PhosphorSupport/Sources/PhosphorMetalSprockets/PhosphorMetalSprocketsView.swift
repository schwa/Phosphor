import MetalSprockets
import MetalSprocketsUI
import PhosphorCompile
import PhosphorModel
import PhosphorRuntime
import SwiftUI

/// SwiftUI render surface that renders a ``PhosphorRuntime`` inside a
/// MetalSprockets `RenderView`, driving PhosphorKit's raw-Metal
/// ``PhosphorRenderer`` via ``PhosphorRenderElement``.
///
/// The host supplies the per-frame ``BuiltinUniforms`` through `makeUniforms`
/// (so the caller owns the playback clock, mouse state, etc.). Frame timing
/// flows back through `onFrameTiming`; `onFrameTick` fires once per frame with
/// the MetalSprockets render context so the caller can advance its clock.
public struct PhosphorMetalSprocketsView: View {
    private let runtime: PhosphorRuntime
    private let userUniformValues: [String: UniformValue]
    private let displayedResource: ResourceID?
    private let makeUniforms: (RenderViewContext, CGSize) -> BuiltinUniforms
    private let onFrameTiming: (FrameTimingStatistics) -> Void
    private let onFrameTick: (RenderViewContext) -> Void

    /// A renderer instance held across frames so its compute pipeline-state
    /// cache survives. Keyed to the runtime's device.
    @State private var renderer: PhosphorRenderer

    public init(
        runtime: PhosphorRuntime,
        userUniformValues: [String: UniformValue] = [:],
        displayedResource: ResourceID? = nil,
        makeUniforms: @escaping (RenderViewContext, CGSize) -> BuiltinUniforms,
        onFrameTiming: @escaping (FrameTimingStatistics) -> Void = { _ in },
        onFrameTick: @escaping (RenderViewContext) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.userUniformValues = userUniformValues
        self.displayedResource = displayedResource
        self.makeUniforms = makeUniforms
        self.onFrameTiming = onFrameTiming
        self.onFrameTick = onFrameTick
        _renderer = State(initialValue: PhosphorRenderer(device: runtime.device))
    }

    public var body: some View {
        RenderView { context, drawableSize in
            PhosphorRenderElement(
                renderer: renderer,
                runtime: runtime,
                builtin: makeUniforms(context, drawableSize),
                userUniformValues: userUniformValues,
                displayedResource: displayedResource
            )
            .onWorkloadEnter { _ in
                onFrameTick(context)
            }
        }
        .metalClearColor(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        .onFrameTimingChange { onFrameTiming($0) }
    }
}
