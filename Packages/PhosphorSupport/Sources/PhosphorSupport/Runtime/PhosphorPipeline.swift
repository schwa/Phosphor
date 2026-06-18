import Foundation
import Metal
import MetalSprockets
import MetalSprocketsAddOns
import MetalSprocketsSupport
import MetalSprocketsUI

/// Per-frame element that runs every compute pass in the environment, then
/// blits the chosen output resource to the drawable via
/// `TextureBillboardPipeline`.
public struct PhosphorPipeline: Element {
    @MSEnvironment(\.device)
    var device

    let runtime: PhosphorRuntime
    let uniforms: BuiltinUniforms
    let drawableSize: CGSize

    public init(runtime: PhosphorRuntime, uniforms: BuiltinUniforms, drawableSize: CGSize) {
        self.runtime = runtime
        self.uniforms = uniforms
        self.drawableSize = drawableSize
    }

    public var body: some Element {
        get throws {
            // Per-frame state setup. Allocates textures if needed (size change,
            // new resource), writes uniforms, rebuilds the per-pass channel
            // argument buffers, and returns the use-resource lists.
            try? runtime.ensureTextures(drawableSize: drawableSize)
            runtime.writeBuiltinUniforms(uniforms)
            let useLists = runtime.rebuildChannelBuffers()

            let enabledPasses = runtime.environment.passes.filter(\.enabled)

            return try Group {
                ForEach(Array(enabledPasses.enumerated()), id: \.offset) { _, pass in
                    try makeComputePass(pass, useResources: useLists[pass.id] ?? [])
                }

                if let outputTexture = runtime.textures[runtime.environment.output]?.readTexture {
                    try RenderPass {
                        try TextureBillboardPipeline(
                            specifierA: .texture2D(outputTexture),
                            specifierB: .color([0, 0, 0])
                        )
                    }
                }
            }
            .onCommandBufferCompleted { [runtime] _ in
                runtime.flipEndOfFrameResources()
            }
        }
    }

    @ElementBuilder
    private func makeComputePass(_ pass: Pass, useResources: [MTLTexture]) throws -> some Element {
        if let function = runtime.passFunctions[pass.id],
           let outTexture = runtime.textures[pass.output]?.writeTexture,
           let channelBuffer = runtime.channelBuffers[pass.id] {
            try ComputePass(label: pass.id.raw) {
                try ComputePipeline(computeKernel: ComputeKernel(function)) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: outTexture.width, height: outTexture.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                    )
                    .parameter("outTexture", texture: outTexture)
                    .parameter("channels", buffer: channelBuffer, offset: 0)
                    .parameter("uniforms", buffer: runtime.uniformsBuffer, offset: 0)
                    .parameter("userUniforms", buffer: runtime.userUniformsBuffer, offset: 0)
                    .onWorkloadEnter { env in
                        guard let encoder = env.computeCommandEncoder else { return }
                        for tex in useResources {
                            encoder.useResource(tex, usage: .read)
                        }
                    }
                }
            }
        }
    }
}

extension PhosphorRuntime {
    /// Called from the command buffer's completion handler. Flips every
    /// `pingPong: true` resource whose `flipTiming` is `.endOfFrame`.
    func flipEndOfFrameResources() {
        var updated = textures
        for resource in environment.resources {
            guard case let .texture2D(id, spec) = resource else { continue }
            guard spec.pingPong, spec.flipTiming == .endOfFrame else { continue }
            updated[id]?.flip()
        }
        textures = updated
    }
}
