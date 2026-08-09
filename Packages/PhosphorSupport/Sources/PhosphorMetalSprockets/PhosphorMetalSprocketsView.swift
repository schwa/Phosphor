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
    private let renderScale: Double

    /// A renderer instance held across frames so its compute pipeline-state
    /// cache survives. Keyed to the runtime's device.
    @State private var renderer: PhosphorRenderer

    #if canImport(MetalFX)
    /// Offscreen target for reduced-resolution rendering. Held across frames so
    /// it's only reallocated when the internal size changes.
    @State private var upscaleTarget = UpscaleTarget()
    #endif

    /// - Parameter renderScale: fraction of the drawable resolution the shader
    ///   pipeline renders at. `1` renders natively; anything smaller renders
    ///   into an offscreen target and MetalFX-upscales it to the drawable.
    public init(
        runtime: PhosphorRuntime,
        userUniformValues: [String: UniformValue] = [:],
        displayedResource: ResourceID? = nil,
        renderScale: Double = 1,
        makeUniforms: @escaping (RenderViewContext, CGSize) -> BuiltinUniforms,
        onFrameTiming: @escaping (FrameTimingStatistics) -> Void = { _ in },
        onFrameTick: @escaping (RenderViewContext) -> Void = { _ in }
    ) {
        self.runtime = runtime
        self.userUniformValues = userUniformValues
        self.displayedResource = displayedResource
        self.renderScale = renderScale
        self.makeUniforms = makeUniforms
        self.onFrameTiming = onFrameTiming
        self.onFrameTick = onFrameTick
        _renderer = State(initialValue: PhosphorRenderer(device: runtime.device))
    }

    public var body: some View {
        RenderView { context, drawableSize in
            try content(context: context, drawableSize: drawableSize)
        }
        .metalColorPixelFormat(UpscaleTarget.pixelFormat)
        // The scaler writes to the drawable from a compute encoder, which a
        // framebuffer-only drawable forbids. Only relax it when upscaling.
        .metalFramebufferOnly(renderScale >= 1)
        .metalClearColor(MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0))
        .onFrameTimingChange { onFrameTiming($0) }
    }

    /// Built outside the `@ElementBuilder` closure so it can do the arithmetic
    /// and texture lookup that a result builder won't allow inline.
    ///
    /// Note this allocates the offscreen target while building the element
    /// tree, which element bodies are otherwise meant to avoid. `MetalFXSpatial`
    /// takes its input texture as a value, so it has to exist before the
    /// element is constructed. The lookup is memoised on size, so it's
    /// idempotent and only allocates on an actual resize — see
    /// docs/MetalSprockets-Usage.md.
    private func content(context: RenderViewContext, drawableSize: CGSize) throws -> some Element {
        let internalSize = Self.internalSize(for: drawableSize, scale: renderScale)
        let offscreen = internalSize == drawableSize
            ? nil
            : upscaleTarget.texture(
                device: runtime.device,
                width: Int(internalSize.width),
                height: Int(internalSize.height)
            )

        return try Group {
            PhosphorRenderElement(
                renderer: renderer,
                runtime: runtime,
                builtin: makeUniforms(context, offscreen == nil ? drawableSize : internalSize),
                userUniformValues: userUniformValues,
                displayedResource: displayedResource,
                targetTexture: offscreen
            )
            .onWorkloadEnter { _ in
                onFrameTick(context)
            }
            if let offscreen {
                PhosphorUpscaleElement(sourceTexture: offscreen)
            }
        }
    }

    /// The pixel size the shader pipeline renders at. Falls back to the
    /// drawable size for scales at or above 1, or if scaling would degenerate.
    static func internalSize(for drawableSize: CGSize, scale: Double) -> CGSize {
        guard scale > 0, scale < 1 else { return drawableSize }
        let width = Int((drawableSize.width * scale).rounded())
        let height = Int((drawableSize.height * scale).rounded())
        guard width >= 1, height >= 1 else { return drawableSize }
        return CGSize(width: width, height: height)
    }
}
