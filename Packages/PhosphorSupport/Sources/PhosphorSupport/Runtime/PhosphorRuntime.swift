import Foundation
import Metal
import Observation

/// Holds the GPU-side state derived from a ``PhosphorEnvironment`` plus a
/// user-supplied source string.
///
/// The runtime is `@Observable` so SwiftUI views can react to recompiles
/// and diagnostics. State that the per-frame element reads (textures,
/// pipelines, channel arg buffers, uniforms buffers) lives here.
@Observable
public final class PhosphorRuntime {
    public let device: MTLDevice
    public private(set) var environment: PhosphorEnvironment
    public private(set) var source: String
    public private(set) var diagnostics: [PhosphorDiagnostic] = []
    /// Compiled `MTLFunction` for each pass, keyed by pass id. The element
    /// wraps each in a `ComputeKernel` and lets MetalSprockets own pipeline
    /// state creation + caching.
    public private(set) var passFunctions: [ResourceID: MTLFunction] = [:]
    public private(set) var library: MTLLibrary?

    /// Cached textures keyed by ``Resource`` id. Allocated lazily by
    /// ``ensureTextures(drawableSize:)``.
    public internal(set) var textures: [ResourceID: PingPongTexture] = [:]

    /// Drawable size used the last time textures were allocated. If the
    /// drawable size changes, all `.drawable`/`.scaledDrawable` resources
    /// are reallocated and zero-filled.
    public private(set) var currentDrawableSize: CGSize = .zero

    /// Per-pass channel argument buffer (Metal 3 bindless). Rebuilt every
    /// frame in ``rebuildChannelBuffers()`` — they're tiny.
    public private(set) var channelBuffers: [ResourceID: MTLBuffer] = [:]

    /// Built-in uniforms buffer. One slot, written each frame.
    public private(set) var uniformsBuffer: MTLBuffer

    /// User uniforms buffer. Sized once per environment; values memcpy'd
    /// each frame.
    public private(set) var userUniformsBuffer: MTLBuffer

    /// 1×1 zero texture used for unbound channel slots, so the GPU never
    /// dereferences a null `MTLResourceID`.
    public private(set) var fallbackTexture: MTLTexture

    public init(device: MTLDevice, environment: PhosphorEnvironment, source: String) throws {
        self.device = device
        self.environment = environment
        self.source = source

        let uniformsLength = max(MemoryLayout<BuiltinUniforms>.stride, 16)
        guard let uniformsBuffer = device.makeBuffer(length: uniformsLength, options: .storageModeShared) else {
            throw PhosphorRuntimeError.allocationFailed("uniforms buffer")
        }
        uniformsBuffer.label = "Phosphor.Uniforms"
        self.uniformsBuffer = uniformsBuffer

        let userUniformsLength = max(Self.userUniformsLength(for: environment.uniforms), 16)
        guard let userUniformsBuffer = device.makeBuffer(length: userUniformsLength, options: .storageModeShared) else {
            throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
        }
        userUniformsBuffer.label = "Phosphor.UserUniforms"
        self.userUniformsBuffer = userUniformsBuffer

        self.fallbackTexture = try Self.makeFallbackTexture(device: device)

        try recompile()
    }

    // MARK: - Document updates

    /// Replace the environment and/or source. Triggers a (synchronous, for now)
    /// recompile.
    public func update(environment: PhosphorEnvironment, source: String) throws {
        self.environment = environment
        self.source = source

        // User-uniforms layout may have changed — reallocate buffer.
        let newLength = max(Self.userUniformsLength(for: environment.uniforms), 16)
        if newLength != userUniformsBuffer.length {
            guard let newBuffer = device.makeBuffer(length: newLength, options: .storageModeShared) else {
                throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
            }
            newBuffer.label = "Phosphor.UserUniforms"
            self.userUniformsBuffer = newBuffer
        }

        try recompile()
    }

    /// Validate + compile the environment's library and per-pass pipeline states.
    /// Surfaces fatal diagnostics on the runtime; per-pass compile errors are
    /// also non-fatal at this layer (failed passes simply don't end up in
    /// ``pipelines``).
    private func recompile() throws {
        var diagnostics = validate(environment)
        let fatal = diagnostics.contains(where: \.isFatal)
        if fatal {
            self.diagnostics = diagnostics
            self.library = nil
            self.passFunctions = [:]
            return
        }

        let compiler = PhosphorCompiler(device: device)
        do {
            let library = try compiler.compileLibrary(environment: environment, userSource: source)
            self.library = library
            var functions: [ResourceID: MTLFunction] = [:]
            for pass in environment.passes where pass.enabled {
                do {
                    functions[pass.id] = try compiler.makeFunction(library: library, for: pass.id)
                } catch {
                    diagnostics.append(.compile(.init(passID: pass.id, rawError: "\(error)")))
                }
            }
            self.passFunctions = functions
        } catch {
            // Whole-library compile failure. Attribute to the first enabled pass
            // for now; future work: parse the Metal error to map line numbers
            // back to specific kernels.
            let attributedTo = environment.passes.first(where: \.enabled)?.id ?? "library"
            diagnostics.append(.compile(.init(passID: attributedTo, rawError: "\(error)")))
            self.library = nil
            self.passFunctions = [:]
        }
        self.diagnostics = diagnostics
    }

    // MARK: - Per-frame state

    /// Make sure textures for every resource exist at the right size for
    /// `drawableSize`. Reallocates resources whose specified size depends on
    /// the drawable when the drawable size changes.
    public func ensureTextures(drawableSize: CGSize) throws {
        let drawableChanged = drawableSize != currentDrawableSize
        currentDrawableSize = drawableSize

        var textures = self.textures
        for resource in environment.resources {
            guard case let .texture2D(id, spec) = resource else { continue }
            let (width, height) = pixelDimensions(for: spec.size, drawableSize: drawableSize)
            let existing = textures[id]
            let dimensionsChanged = existing?.a.width != width || existing?.a.height != height
            let pingPongChanged = existing?.pingPong != spec.pingPong
            let resizeRequired = (drawableChanged && dimensionDependsOnDrawable(spec.size))
                || existing == nil
                || dimensionsChanged
                || pingPongChanged
            guard resizeRequired else { continue }

            textures[id] = try allocate(id: id, spec: spec, width: width, height: height)
        }

        // Drop textures for resources that no longer exist.
        let liveIDs = Set(environment.resources.map(\.id))
        for staleID in textures.keys where !liveIDs.contains(staleID) {
            textures.removeValue(forKey: staleID)
        }

        self.textures = textures
    }

    /// Write the built-in uniforms into a fresh ``uniformsBuffer``.
    ///
    /// Allocates a new MTLBuffer per frame. The previous frame's buffer may
    /// still be in flight on the GPU; overwriting shared-storage buffers
    /// while the GPU reads them causes intermittent page faults.
    public func writeBuiltinUniforms(_ uniforms: BuiltinUniforms) {
        var copy = uniforms
        copy.channelCount = UInt32(channelCount(for: environment))
        let length = MemoryLayout<BuiltinUniforms>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return }
        buffer.label = "Phosphor.Uniforms"
        memcpy(buffer.contents(), &copy, MemoryLayout<BuiltinUniforms>.size)
        uniformsBuffer = buffer
    }

    /// Build per-pass channel argument buffers. Tiny — one MTLResourceID per
    /// channel slot — so we rebuild every frame instead of diffing.
    ///
    /// Returns the set of textures the encoder must call `useResource` on for
    /// each pass (so they're resident when the GPU dereferences the argument
    /// buffer).
    public func rebuildChannelBuffers() -> [ResourceID: [MTLTexture]] {
        var resourceUseLists: [ResourceID: [MTLTexture]] = [:]
        var newBuffers: [ResourceID: MTLBuffer] = [:]
        let slotCount = channelCount(for: environment)
        let bufferLength = max(slotCount * MemoryLayout<MTLResourceID>.stride, 16)

        for pass in environment.passes where pass.enabled {
            // Always allocate a fresh buffer per frame. The previous frame's
            // buffer may still be in flight on the GPU and overwriting it
            // mid-flight causes intermittent GPU page faults. These buffers
            // are tiny (a handful of MTLResourceIDs) so the allocation cost
            // is negligible.
            guard let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else { continue }
            buffer.label = "Phosphor.Channels.\(pass.id.raw)"

            let ptr = buffer.contents().bindMemory(to: MTLResourceID.self, capacity: max(slotCount, 1))
            var useList: [MTLTexture] = []

            for slot in 0..<slotCount {
                let channelName = "iChannel\(slot)"
                let resourceID = pass.inputs.first { $0.name == channelName }?.resource
                let texture = resourceID.flatMap { textures[$0]?.readTexture } ?? fallbackTexture
                ptr[slot] = texture.gpuResourceID
                useList.append(texture)
            }

            newBuffers[pass.id] = buffer
            resourceUseLists[pass.id] = useList
        }

        self.channelBuffers = newBuffers
        return resourceUseLists
    }

    // MARK: - Helpers

    private func allocate(id: ResourceID, spec: Texture2DSpec, width: Int, height: Int) throws -> PingPongTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mtlPixelFormat(spec.format),
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor) else {
            throw PhosphorRuntimeError.allocationFailed("texture \(id.raw) (a)")
        }
        a.label = "Phosphor.\(id.raw).a"

        let b: MTLTexture
        if spec.pingPong {
            guard let madeB = device.makeTexture(descriptor: descriptor) else {
                throw PhosphorRuntimeError.allocationFailed("texture \(id.raw) (b)")
            }
            madeB.label = "Phosphor.\(id.raw).b"
            b = madeB
        } else {
            b = a
        }

        // TODO: honor spec.initial. .zero is implicit (storage mode private +
        // first compute write); .color / .image / .noise require an
        // initialization pass. Not needed for step 5.
        return PingPongTexture(pingPong: spec.pingPong, a: a, b: b)
    }

    private func pixelDimensions(for size: TextureSize, drawableSize: CGSize) -> (Int, Int) {
        switch size {
        case .drawable:
            return (max(1, Int(drawableSize.width.rounded())), max(1, Int(drawableSize.height.rounded())))
        case .fixed(let width, let height):
            return (max(1, width), max(1, height))
        case .scaledDrawable(let scale):
            return (
                max(1, Int((Float(drawableSize.width) * scale).rounded())),
                max(1, Int((Float(drawableSize.height) * scale).rounded()))
            )
        }
    }

    private func dimensionDependsOnDrawable(_ size: TextureSize) -> Bool {
        switch size {
        case .drawable, .scaledDrawable: return true
        case .fixed: return false
        }
    }

    private func mtlPixelFormat(_ format: PhosphorPixelFormat) -> MTLPixelFormat {
        switch format {
        case .rgba8Unorm: return .rgba8Unorm
        case .rgba16Float: return .rgba16Float
        case .rgba32Float: return .rgba32Float
        }
    }

    private static func userUniformsLength(for uniforms: [UniformDecl]) -> Int {
        // Use an overestimate that covers MSL alignment. Fields are at most 16
        // bytes (`float4`/`float3`), aligned to at most 16. 32 bytes per slot
        // is conservative.
        max(uniforms.count, 1) * 32
    }

    private static func makeFallbackTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: 1,
            height: 1,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PhosphorRuntimeError.allocationFailed("fallback texture")
        }
        texture.label = "Phosphor.Fallback"
        var zero = SIMD4<Float>(0, 0, 0, 0)
        let region = MTLRegion(origin: .init(x: 0, y: 0, z: 0), size: .init(width: 1, height: 1, depth: 1))
        texture.replace(region: region, mipmapLevel: 0, withBytes: &zero, bytesPerRow: 16)
        return texture
    }
}

public enum PhosphorRuntimeError: Error, Hashable, Sendable, CustomStringConvertible {
    case allocationFailed(String)

    public var description: String {
        switch self {
        case .allocationFailed(let what): return "PhosphorRuntime: failed to allocate \(what)"
        }
    }
}
