import Foundation
import PhosphorModel
import Metal
import MetalSprockets
import MetalSprocketsAddOns
import MetalSprocketsSupport
import MetalSprocketsUI

/// Per-frame element that runs every compute pass in the configuration, then
/// blits the config's `output` texture to the drawable via
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
    /// Resource id whose latest write target gets blitted to the drawable.
    /// Defaults to `configuration.output`; the host can override this to
    /// preview an intermediate ping-pong / scratch resource.
    let displayedResource: ResourceID?

    public init(
        runtime: PhosphorRuntime,
        uniforms: BuiltinUniforms,
        userUniformValues: [String: UniformValue] = [:],
        drawableSize: CGSize,
        displayedResource: ResourceID? = nil
    ) {
        self.runtime = runtime
        self.uniforms = uniforms
        self.userUniformValues = userUniformValues
        self.drawableSize = drawableSize
        self.displayedResource = displayedResource
    }

    public var body: some Element {
        get throws {
            try? runtime.ensureTextures(drawableSize: drawableSize)
            runtime.writeAudioBuffers()
            runtime.writeUserUniforms(userUniformValues)

            // Parity for every ping-pong texture derived from the frame count.
            // Non-ping-pong textures still get an entry (always true) so
            // downstream lookups don't have to special-case them.
            let isEvenFrame = (UInt64(uniforms.frame) % 2) == 0
            var parityByResource: [ResourceID: Bool] = [:]
            for texture in runtime.configuration.textures {
                parityByResource[texture.id] = (texture.swap != .none) ? isEvenFrame : true
            }
            let useLists = runtime.writePassUniforms(builtin: uniforms, parity: parityByResource)

            // The billboard samples this frame's *write* target of the
            // chosen output texture — same parity as the writing pass.
            let outputResourceID: ResourceID = {
                if let chosen = displayedResource,
                   runtime.textures[chosen] != nil {
                    return chosen
                }
                return runtime.configuration.output
            }()
            let outputTexture = runtime.textures[outputResourceID]?.writeTexture(currentIsA: parityByResource[outputResourceID] ?? true)

            let enabledPasses = runtime.configuration.passes.filter(\.enabled)

            return try Group {
                ForEach(Array(enabledPasses.enumerated()), id: \.offset) { _, pass in
                    try makeComputePass(
                        pass,
                        parity: parityByResource,
                        useResources: useLists[pass.id] ?? []
                    )
                }

                if let outputTexture {
                    let textureCoordinates: Quad = runtime.configuration.flipY
                        ? Quad(min: [0, 1], max: [1, 0])
                        : .unit
                    try RenderPass {
                        try TextureBillboardPipeline(
                            specifierA: .texture2D(outputTexture),
                            specifierB: .color([0, 0, 0]),
                            textureCoordinates: textureCoordinates
                        )
                    }
                }
            }
        }
    }

    /// Finds the texture this pass writes to, using its first
    /// `.write` / `.readWrite` binding. Dispatch grid size matches that
    /// texture's dimensions.
    private func primaryWriteTexture(for pass: Pass, parity: [ResourceID: Bool]) -> MTLTexture? {
        guard let binding = pass.textures.first(where: { $0.access == .write || $0.access == .readWrite }) else {
            return nil
        }
        let resourceParity = parity[binding.id] ?? true
        return runtime.textures[binding.id]?.writeTexture(currentIsA: resourceParity)
    }

    @ElementBuilder
    private func makeComputePass(
        _ pass: Pass,
        parity: [ResourceID: Bool],
        useResources: [MTLTexture]
    ) throws -> some Element {
        if let function = runtime.passFunctions[pass.id],
           let dispatchTarget = primaryWriteTexture(for: pass, parity: parity),
           let passBuffer = runtime.passUniformsBuffer(for: pass.id) {
            try ComputePass(label: pass.id.raw) {
                try ComputePipeline(computeKernel: ComputeKernel(function)) {
                    try ComputeDispatch(
                        threadsPerGrid: MTLSize(width: dispatchTarget.width, height: dispatchTarget.height, depth: 1),
                        threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
                    )
                    .parameter("uniforms", buffer: passBuffer, offset: 0)
                    .parameter("userUniforms", buffer: runtime.userUniformsBuffer, offset: 0)
                    .onWorkloadEnter { [runtime] config in
                        guard let encoder = config.computeCommandEncoder else { return }
                        for tex in useResources {
                            encoder.useResource(tex, usage: [.read, .write])
                        }
                        // The Uniforms argument buffer references the audio
                        // buffers via their gpuAddress; mark them resident.
                        encoder.useResource(runtime.waveformBuffer, usage: .read)
                        encoder.useResource(runtime.spectrumBuffer, usage: .read)
                    }
                }
            }
        }
    }
}
