import Foundation
import Metal
import MetalSprockets
import MetalSprocketsAddOns
import MetalSprocketsSupport
import MetalSprocketsUI

/// Per-frame element that runs every compute pass in the environment, then
/// blits the chosen output resource to the drawable via
/// `TextureBillboardPipeline`.
///
/// Ping-pong parity is derived directly from the frame counter — no state.
/// Even frames use parity A; odd frames use parity B. Deterministic; no
/// cross-thread bookkeeping.
public struct PhosphorPipeline: Element {
    @MSEnvironment(\.device)
    var device

    let runtime: PhosphorRuntime
    let uniforms: BuiltinUniforms
    let userUniformValues: [String: UniformValue]
    let drawableSize: CGSize

    public init(
        runtime: PhosphorRuntime,
        uniforms: BuiltinUniforms,
        userUniformValues: [String: UniformValue] = [:],
        drawableSize: CGSize
    ) {
        self.runtime = runtime
        self.uniforms = uniforms
        self.userUniformValues = userUniformValues
        self.drawableSize = drawableSize
    }

    public var body: some Element {
        get throws {
            try? runtime.ensureTextures(drawableSize: drawableSize)
            runtime.writeBuiltinUniforms(uniforms)
            runtime.writeUserUniforms(userUniformValues)

            // Parity for every ping-pong resource derived from the frame count.
            // Non-ping-pong resources still get a parity entry (always true) so
            // downstream lookups don't have to special-case them.
            let isEvenFrame = (UInt64(uniforms.frame) % 2) == 0
            var parityByResource: [ResourceID: Bool] = [:]
            for resource in runtime.environment.resources {
                if case let .texture2D(id, spec) = resource {
                    parityByResource[id] = spec.pingPong ? isEvenFrame : true
                }
            }
            let useLists = runtime.writeChannelBuffers(parity: parityByResource)

            // The billboard samples this frame's *write* target — same parity
            // as the writing pass.
            let outputResourceID = runtime.environment.output
            let outputTexture = runtime.textures[outputResourceID]?.writeTexture(currentIsA: parityByResource[outputResourceID] ?? true)

            let enabledPasses = runtime.environment.passes.filter(\.enabled)

            return try Group {
                ForEach(Array(enabledPasses.enumerated()), id: \.offset) { _, pass in
                    try makeComputePass(
                        pass,
                        parity: parityByResource[pass.output] ?? true,
                        useResources: useLists[pass.id] ?? []
                    )
                }

                if let outputTexture {
                    try RenderPass {
                        try TextureBillboardPipeline(
                            specifierA: .texture2D(outputTexture),
                            specifierB: .color([0, 0, 0])
                        )
                    }
                }
            }
        }
    }

    @ElementBuilder
    private func makeComputePass(_ pass: Pass, parity: Bool, useResources: [MTLTexture]) throws -> some Element {
        if let function = runtime.passFunctions[pass.id],
           let outTexture = runtime.textures[pass.output]?.writeTexture(currentIsA: parity),
           let channelBuffer = runtime.channelBuffer(for: pass.id) {
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
