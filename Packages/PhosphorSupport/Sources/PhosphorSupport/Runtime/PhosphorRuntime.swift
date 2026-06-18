import Foundation
import Metal
import Observation
import os

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
    public private(set) var textures: [ResourceID: PingPongTexture] = [:]

    /// Drawable size used the last time textures were allocated. If the
    /// drawable size changes, all `.drawable`/`.scaledDrawable` resources
    /// are reallocated and zero-filled.
    public private(set) var currentDrawableSize: CGSize = .zero

    /// Per-pass channel argument buffers (Metal 3 bindless). Rebuilt every
    /// frame against the current parity table to support multi-resource
    /// pipelines where a pass reads a ping-pong resource owned by a different
    /// pass. See ``writeChannelBuffers(parity:)``.
    private var channelBuffers: [ResourceID: MTLBuffer] = [:]

    /// Returns the channel argument buffer for `pass` (set during the most
    /// recent ``writeChannelBuffers(parity:)`` call).
    public func channelBuffer(for pass: ResourceID) -> MTLBuffer? {
        channelBuffers[pass]
    }

    /// Built-in uniforms buffer. One slot, written each frame.
    public private(set) var uniformsBuffer: MTLBuffer

    /// User uniforms buffer. Sized to ``UserUniformsLayout/totalSize`` for
    /// the current environment; allocated fresh per frame to dodge in-flight
    /// races (see issue #6).
    public private(set) var userUniformsBuffer: MTLBuffer

    /// Computed layout for `env.uniforms`. Used to pack values and to size
    /// the per-frame `userUniformsBuffer`.
    public private(set) var userUniformsLayout: UserUniformsLayout.Layout

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

        let userUniformsLayout = UserUniformsLayout.compute(for: environment.uniforms)
        let userUniformsLength = max(userUniformsLayout.totalSize, 16)
        guard let userUniformsBuffer = device.makeBuffer(length: userUniformsLength, options: .storageModeShared) else {
            throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
        }
        userUniformsBuffer.label = "Phosphor.UserUniforms"
        self.userUniformsBuffer = userUniformsBuffer
        self.userUniformsLayout = userUniformsLayout

        self.fallbackTexture = try Self.makeFallbackTexture(device: device)

        try recompile()
    }

    // MARK: - Document updates

    /// Replace the environment and/or source. Triggers a (synchronous, for now)
    /// recompile.
    public func update(environment: PhosphorEnvironment, source: String) throws {
        self.environment = environment
        self.source = source

        // User-uniforms layout may have changed — recompute and reallocate.
        let newLayout = UserUniformsLayout.compute(for: environment.uniforms)
        let newLength = max(newLayout.totalSize, 16)
        if newLength != userUniformsBuffer.length {
            guard let newBuffer = device.makeBuffer(length: newLength, options: .storageModeShared) else {
                throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
            }
            newBuffer.label = "Phosphor.UserUniforms"
            self.userUniformsBuffer = newBuffer
        }
        self.userUniformsLayout = newLayout

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
        logDiagnostics(diagnostics)
    }

    private func logDiagnostics(_ diagnostics: [PhosphorDiagnostic]) {
        guard !diagnostics.isEmpty else { return }
        for diagnostic in diagnostics {
            switch diagnostic {
            case .compile(let error):
                Self.logger.error("[Phosphor] compile error in '\(error.passID.raw, privacy: .public)':\n\(error.rawError, privacy: .public)")
            default:
                Self.logger.error("[Phosphor] \(String(describing: diagnostic), privacy: .public)")
            }
        }
    }

    private static let logger = Logger(subsystem: "io.schwa.PhosphorSupport", category: "runtime")

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
            let dimensionsChanged = (existing != nil) && (existing!.a.width != width || existing!.a.height != height)
            let pingPongChanged = (existing != nil) && (existing!.pingPong != spec.pingPong)
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

    /// Writes per-pass channel argument buffers for the current frame.
    ///
    /// For each channel slot the rule is:
    ///
    /// - If the sampled resource is the same as the pass's output (i.e.
    ///   self-feedback like Game of Life), bind `readTexture` for that
    ///   resource's parity — the kernel reads last frame's contents.
    /// - If the sampled resource is written by an *earlier* pass this frame,
    ///   bind `writeTexture` for that resource's parity — the kernel sees
    ///   the upstream pass's just-written data, no one-frame lag.
    /// - Otherwise (resource not written this frame, or self-feedback for
    ///   non-pingpong), bind `readTexture` and we get last frame's data.
    ///
    /// Allocates a fresh MTLBuffer per pass per frame to avoid in-flight
    /// read races.
    public func writeChannelBuffers(parity: [ResourceID: Bool]) -> [ResourceID: [MTLTexture]] {
        let slotCount = channelCount(for: environment)
        let bufferLength = max(slotCount * MemoryLayout<MTLResourceID>.stride, 16)
        var newBuffers: [ResourceID: MTLBuffer] = [:]
        var useLists: [ResourceID: [MTLTexture]] = [:]

        // Track which resources have been written so far this frame as we walk
        // the pass list in order. A pass's inputs that sample one of these
        // resources (and aren't self-feedback) get the writeTexture (just-
        // written data); inputs that sample a not-yet-written resource get
        // the readTexture (last frame).
        var alreadyWritten: Set<ResourceID> = []

        for pass in environment.passes where pass.enabled {
            guard let buffer = device.makeBuffer(length: bufferLength, options: .storageModeShared) else { continue }
            buffer.label = "Phosphor.Channels.\(pass.id.raw)"
            let ptr = buffer.contents().bindMemory(to: MTLResourceID.self, capacity: max(slotCount, 1))
            var useList: [MTLTexture] = []

            for slot in 0..<slotCount {
                let channelName = "iChannel\(slot)"
                let resourceID = pass.inputs.first { $0.name == channelName }?.resource
                let texture: MTLTexture
                if let resourceID, let ping = textures[resourceID] {
                    let resourceParity = parity[resourceID] ?? true
                    let isSelfFeedback = resourceID == pass.output
                    if !isSelfFeedback && alreadyWritten.contains(resourceID) {
                        // Upstream pass wrote this resource earlier this frame.
                        // Read what they just wrote.
                        texture = ping.writeTexture(currentIsA: resourceParity)
                    } else {
                        // Self-feedback, or a resource not written this frame.
                        // Read last frame's contents.
                        texture = ping.readTexture(currentIsA: resourceParity)
                    }
                } else {
                    texture = fallbackTexture
                }
                ptr[slot] = texture.gpuResourceID
                useList.append(texture)
            }

            newBuffers[pass.id] = buffer
            useLists[pass.id] = useList
            alreadyWritten.insert(pass.output)
        }

        self.channelBuffers = newBuffers
        return useLists
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

    /// Allocates a fresh user-uniforms buffer and packs `values` into it via
    /// ``UserUniformsLayout``. Falls back to declared defaults for any name
    /// not present in `values`. Same per-frame-alloc dodge as the built-in
    /// uniforms buffer; tracked by issue #6.
    public func writeUserUniforms(_ values: [String: UniformValue]) {
        let length = max(userUniformsLayout.totalSize, 16)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return }
        buffer.label = "Phosphor.UserUniforms"
        let defaults = UserUniformsLayout.defaultsDictionary(environment.uniforms)
        UserUniformsLayout.pack(
            values: values,
            defaults: defaults,
            layout: userUniformsLayout,
            into: buffer.contents()
        )
        userUniformsBuffer = buffer
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
