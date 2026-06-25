import Metal
import MetalSprockets
import PhosphorCompile
import PhosphorModel
import PhosphorRuntime

/// Builds a MetalSprockets element that drives PhosphorKit's raw-Metal
/// ``PhosphorRenderer`` for one frame.
///
/// Uses only MetalSprockets' public API: an `EmptyElement` with an
/// `.onWorkloadEnter` modifier that reads the command buffer and current
/// drawable from the environment and hands them to
/// ``PhosphorRenderer/render(runtime:into:targetTexture:drawableSize:builtin:userUniformValues:displayedResource:)``,
/// which creates its own compute/render encoders.
///
/// Place it directly inside a `RenderView`'s content (not inside a
/// `ComputePass`/`RenderPass`) so the command buffer is free for the renderer's
/// own encoders. This is the bridge that keeps PhosphorKit MetalSprockets-free
/// while letting the app render Phosphor shaders inside a MetalSprockets
/// `RenderView` (for frame timing and, later, video import/export).
@MainActor
public func PhosphorRenderElement(
    renderer: PhosphorRenderer,
    runtime: PhosphorRuntime,
    builtin: BuiltinUniforms,
    userUniformValues: [String: UniformValue] = [:],
    displayedResource: ResourceID? = nil
) -> some Element {
    EmptyElement()
        .onWorkloadEnter { environment in
            guard let commandBuffer = environment.commandBuffer,
                  let drawable = environment.currentDrawable else {
                return
            }
            let targetTexture = drawable.texture
            let drawableSize = environment.drawableSize
                ?? CGSize(width: targetTexture.width, height: targetTexture.height)

            try renderer.render(
                runtime: runtime,
                into: commandBuffer,
                targetTexture: targetTexture,
                drawableSize: drawableSize,
                builtin: builtin,
                userUniformValues: userUniformValues,
                displayedResource: displayedResource
            )
        }
}
