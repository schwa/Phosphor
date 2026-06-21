import Foundation
import Metal
import MetalKit
import Observation
import os

/// Holds the GPU-side state derived from a ``PhosphorConfiguration`` plus a
/// user-supplied source string.
///
/// The runtime is `@Observable` so SwiftUI views can react to recompiles
/// and diagnostics. State that the per-frame element reads (textures,
/// pipelines, per-pass uniforms buffers) lives here.
@Observable
public final class PhosphorRuntime {
    public let device: MTLDevice
    public private(set) var configuration: PhosphorConfiguration
    public private(set) var source: String
    public private(set) var diagnostics: [PhosphorDiagnostic] = []

    /// Compiled `MTLFunction` for each pass, keyed by pass id.
    public private(set) var passFunctions: [ResourceID: MTLFunction] = [:]
    public private(set) var library: MTLLibrary?

    /// Cached textures keyed by id. Allocated lazily by
    /// ``ensureTextures(drawableSize:)``.
    public private(set) var textures: [ResourceID: PingPongTexture] = [:]

    /// Drawable size used the last time textures were allocated. If the
    /// drawable size changes, all `.drawable`/`.scaledDrawable` resources
    /// are reallocated and zero-filled.
    public private(set) var currentDrawableSize: CGSize = .zero

    /// Set whenever a texture is (re)allocated or the host explicitly calls
    /// ``signalReset()``; cleared by the next call to ``writeBuiltinUniforms(_:)``.
    /// Surfaced to kernels via `Uniforms.resized`.
    private var resizedFlag: Bool = false

    public func signalReset() {
        resizedFlag = true
        for (_, pair) in textures where pair.pingPong {
            zeroTexture(pair.a)
            zeroTexture(pair.b)
        }
    }

    private func zeroTexture(_ texture: MTLTexture) {
        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else { return }
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba8Unorm: bytesPerPixel = 4
        case .bgra8Unorm: bytesPerPixel = 4
        case .rgba16Float: bytesPerPixel = 8
        case .rgba32Float: bytesPerPixel = 16
        default: bytesPerPixel = 16
        }
        let bytesPerRow = texture.width * bytesPerPixel
        let length = bytesPerRow * texture.height
        guard let zero = device.makeBuffer(length: length, options: .storageModeShared) else {
            encoder.endEncoding()
            return
        }
        memset(zero.contents(), 0, length)
        encoder.copy(
            from: zero, sourceOffset: 0, sourceBytesPerRow: bytesPerRow,
            sourceBytesPerImage: length,
            sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
            to: texture, destinationSlice: 0, destinationLevel: 0,
            destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0)
        )
        encoder.endEncoding()
        commandBuffer.commit()
    }

    /// Per-pass uniforms buffers. Each pass gets its own MTLBuffer carrying
    /// the BuiltinUniforms scalar prefix followed by the nested Textures
    /// argument-buffer field (one MTLResourceID per binding). Rebuilt every
    /// frame; per-frame alloc dodges in-flight read races.
    private var passUniformsBuffers: [ResourceID: MTLBuffer] = [:]

    public func passUniformsBuffer(for pass: ResourceID) -> MTLBuffer? {
        passUniformsBuffers[pass]
    }

    /// User uniforms buffer. Sized to ``UserUniformsLayout/totalSize`` for
    /// the current configuration.
    public private(set) var userUniformsBuffer: MTLBuffer

    public private(set) var userUniformsLayout: UserUniformsLayout.Layout

    public private(set) var fallbackTexture: MTLTexture

    public private(set) var waveformBuffer: MTLBuffer
    public private(set) var spectrumBuffer: MTLBuffer

    public static let waveformSampleCount: Int = 1_024
    public static let spectrumBinCount: Int = 512

    public weak var audioCapture: AudioCaptureEngine?
    private var spectrumAnalyzer: SpectrumAnalyzer?

    public private(set) var assets: [String: PhosphorAsset]

    @ObservationIgnored
    private let textureLoader: MTKTextureLoader

    /// Builds a runtime from a configuration. GPU resource creation is
    /// assumed not to fail in practice (tiny buffers, a 1×1 texture, the
    /// system default device); any failure is unrecoverable and traps.
    public init(configuration: PhosphorConfiguration = PhosphorConfiguration(output: "image"), source: String = "", assets: [String: PhosphorAsset] = [:]) {
        do {
            guard let device = MTLCreateSystemDefaultDevice() else {
                throw PhosphorRuntimeError.allocationFailed("Metal device")
            }
            self.device = device
            self.configuration = configuration
            self.source = source
            self.assets = assets
            self.textureLoader = MTKTextureLoader(device: device)

            let userUniformsLayout = UserUniformsLayout.compute(for: configuration.uniforms)
            let userUniformsLength = max(userUniformsLayout.totalSize, 16)
            guard let userUniformsBuffer = device.makeBuffer(length: userUniformsLength, options: .storageModeShared) else {
                throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
            }
            userUniformsBuffer.label = "Phosphor.UserUniforms"
            self.userUniformsBuffer = userUniformsBuffer
            self.userUniformsLayout = userUniformsLayout

            self.fallbackTexture = try Self.makeFallbackTexture(device: device)

            let waveformLength = Self.waveformSampleCount * MemoryLayout<Float>.stride
            guard let waveformBuffer = device.makeBuffer(length: waveformLength, options: .storageModeShared) else {
                throw PhosphorRuntimeError.allocationFailed("waveform buffer")
            }
            waveformBuffer.label = "Phosphor.AudioWaveform"
            memset(waveformBuffer.contents(), 0, waveformLength)
            self.waveformBuffer = waveformBuffer

            let spectrumLength = Self.spectrumBinCount * MemoryLayout<Float>.stride
            guard let spectrumBuffer = device.makeBuffer(length: spectrumLength, options: .storageModeShared) else {
                throw PhosphorRuntimeError.allocationFailed("spectrum buffer")
            }
            spectrumBuffer.label = "Phosphor.AudioSpectrum"
            memset(spectrumBuffer.contents(), 0, spectrumLength)
            self.spectrumBuffer = spectrumBuffer

            let compiled = ShaderCompiler.compile(configuration: configuration, userSource: source, device: device)
            self.library = compiled.library
            self.passFunctions = compiled.passFunctions
            self.diagnostics = compiled.diagnostics
            logDiagnostics(compiled.diagnostics)
        } catch {
            // TODO: surface this instead of trapping once we have a UI path.
            fatalError("PhosphorRuntime initialization failed: \(error)")
        }
    }

    /// Reloads in place from a freshly parsed source. A source with no
    /// front-matter resets to an empty configuration. GPU/compile failures
    /// are assumed not to occur (compile errors land in `diagnostics`, not
    /// thrown); any real failure traps.
    public func reload(parsed: ParsedPhosphorSource, assets: [String: PhosphorAsset], audioCapture: AudioCaptureEngine?) {
        self.audioCapture = audioCapture
        update(parsed: parsed, assets: assets)
    }

    /// Updates the runtime from an already-parsed source. Validation is not
    /// re-run: the parse step's diagnostics are authoritative (issue #42).
    public func update(parsed: ParsedPhosphorSource, assets: [String: PhosphorAsset] = [:]) {
        applyConfiguration(parsed.configuration, source: parsed.body, assets: assets) {
            ShaderCompiler.compile(parsed: parsed, device: device)
        }
    }

    private func applyConfiguration(
        _ configuration: PhosphorConfiguration,
        source: String,
        assets: [String: PhosphorAsset],
        compile: () -> CompiledShader
    ) {
        do {
            self.configuration = configuration
            self.source = source
            self.assets = assets

            let newLayout = UserUniformsLayout.compute(for: configuration.uniforms)
            let newLength = max(newLayout.totalSize, 16)
            if newLength != userUniformsBuffer.length {
                guard let newBuffer = device.makeBuffer(length: newLength, options: .storageModeShared) else {
                    throw PhosphorRuntimeError.allocationFailed("user uniforms buffer")
                }
                newBuffer.label = "Phosphor.UserUniforms"
                self.userUniformsBuffer = newBuffer
            }
            self.userUniformsLayout = newLayout

            let compiled = compile()
            self.library = compiled.library
            self.passFunctions = compiled.passFunctions
            self.diagnostics = compiled.diagnostics
            logDiagnostics(compiled.diagnostics)
        } catch {
            // TODO: surface this instead of trapping once we have a UI path.
            fatalError("PhosphorRuntime update failed: \(error)")
        }
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

    /// Allocate textures for every declared resource at the right size for
    /// `drawableSize`. Idempotent for resources whose size doesn't depend
    /// on the drawable.
    public func ensureTextures(drawableSize: CGSize) throws {
        let drawableChanged = drawableSize != currentDrawableSize
        currentDrawableSize = drawableSize

        var liveIDs: Set<ResourceID> = []
        for texture in configuration.textures {
            liveIDs.insert(texture.id)
            let existing = textures[texture.id]
            let (width, height) = pixelDimensions(for: texture.size, drawableSize: drawableSize)
            let dimensionsChanged = (existing != nil) && (existing!.a.width != width || existing!.a.height != height)
            let pingPong = texture.swap != .none
            let pingPongChanged = (existing != nil) && (existing!.pingPong != pingPong)
            let resizeRequired = (drawableChanged && dimensionDependsOnDrawable(texture.size))
                || existing == nil
                || dimensionsChanged
                || pingPongChanged
            guard resizeRequired else { continue }

            textures[texture.id] = try allocate(texture: texture, width: width, height: height)
            resizedFlag = true
        }

        for staleID in textures.keys where !liveIDs.contains(staleID) {
            textures.removeValue(forKey: staleID)
        }
    }

    public func writeAudioBuffers() {
        let waveformPtr = waveformBuffer.contents().bindMemory(to: Float.self, capacity: Self.waveformSampleCount)
        let spectrumPtr = spectrumBuffer.contents().bindMemory(to: Float.self, capacity: Self.spectrumBinCount)
        if let capture = audioCapture, capture.isRunningNonisolated {
            capture.copyLatestSamples(into: waveformPtr)
            if spectrumAnalyzer == nil {
                spectrumAnalyzer = SpectrumAnalyzer(
                    sampleCount: Self.waveformSampleCount,
                    binCount: Self.spectrumBinCount
                )
            }
            spectrumAnalyzer?.process(samples: waveformPtr, into: spectrumPtr)
        } else {
            memset(waveformBuffer.contents(), 0, Self.waveformSampleCount * MemoryLayout<Float>.stride)
            memset(spectrumBuffer.contents(), 0, Self.spectrumBinCount * MemoryLayout<Float>.stride)
        }
    }

    /// Writes one MTLBuffer per pass containing the BuiltinUniforms prefix
    /// followed by the texture handles for that pass's bindings. Allocates
    /// a fresh buffer per pass per frame to avoid in-flight write races.
    ///
    /// `builtin` is the BuiltinUniforms values to use as the prefix; the
    /// runtime fills in `resized`, `waveform`, and `spectrum` itself.
    /// `parity` carries the ping-pong parity for each ping-pong texture.
    ///
    /// Returns a map of pass id → use-list of textures the kernel will
    /// touch; the per-frame element passes that to `encoder.useResource`.
    public func writePassUniforms(builtin: BuiltinUniforms, parity: [ResourceID: Bool]) -> [ResourceID: [MTLTexture]] {
        var copy = builtin
        copy.resized = resizedFlag ? 1 : 0
        resizedFlag = false
        copy.waveform = waveformBuffer.gpuAddress
        copy.spectrum = spectrumBuffer.gpuAddress

        let builtinSize = MemoryLayout<BuiltinUniforms>.size
        let builtinStride = MemoryLayout<BuiltinUniforms>.stride
        let handleStride = MemoryLayout<MTLResourceID>.stride

        var newBuffers: [ResourceID: MTLBuffer] = [:]
        var useLists: [ResourceID: [MTLTexture]] = [:]

        // Track which textures have been written so far this frame so a
        // downstream pass reading the same id sees just-written data.
        var alreadyWritten: Set<ResourceID> = []

        for pass in configuration.passes where pass.enabled {
            // Buffer layout: [BuiltinUniforms prefix][N × MTLResourceID]
            let handleCount = pass.textures.count
            let length = builtinStride + handleCount * handleStride
            guard let buffer = device.makeBuffer(length: max(length, 16), options: .storageModeShared) else { continue }
            buffer.label = "Phosphor.Uniforms.\(pass.id.raw)"

            // Prefix.
            withUnsafePointer(to: copy) { srcPtr in
                memcpy(buffer.contents(), srcPtr, builtinSize)
            }

            // Texture handles.
            let handlePtr = buffer.contents().advanced(by: builtinStride).assumingMemoryBound(to: MTLResourceID.self)
            var useList: [MTLTexture] = []
            for (index, binding) in pass.textures.enumerated() {
                let texture: MTLTexture
                if let pair = textures[binding.id] {
                    let resourceParity = parity[binding.id] ?? true
                    switch binding.access {
                    case .write, .readWrite:
                        texture = pair.writeTexture(currentIsA: resourceParity)

                    case .read, .sample:
                        let isSelfFeedback = pass.textures.contains { $0.id == binding.id && ($0.access == .write || $0.access == .readWrite) }
                        if !isSelfFeedback, alreadyWritten.contains(binding.id) {
                            texture = pair.writeTexture(currentIsA: resourceParity)
                        } else {
                            texture = pair.readTexture(currentIsA: resourceParity)
                        }
                    }
                } else {
                    texture = fallbackTexture
                }
                handlePtr[index] = texture.gpuResourceID
                useList.append(texture)
            }

            newBuffers[pass.id] = buffer
            useLists[pass.id] = useList

            // Record any write targets of this pass for downstream lookups.
            for binding in pass.textures where binding.access == .write || binding.access == .readWrite {
                alreadyWritten.insert(binding.id)
            }
        }

        self.passUniformsBuffers = newBuffers
        return useLists
    }

    public func writeUserUniforms(_ values: [String: UniformValue]) {
        let length = max(userUniformsLayout.totalSize, 16)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return }
        buffer.label = "Phosphor.UserUniforms"
        let defaults = UserUniformsLayout.defaultsDictionary(configuration.uniforms)
        UserUniformsLayout.pack(
            values: values,
            defaults: defaults,
            layout: userUniformsLayout,
            into: buffer.contents()
        )
        userUniformsBuffer = buffer
    }

    // MARK: - Allocation

    private func allocate(texture: Texture, width: Int, height: Int) throws -> PingPongTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: mtlPixelFormat(texture.format),
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let a = device.makeTexture(descriptor: descriptor) else {
            throw PhosphorRuntimeError.allocationFailed("texture \(texture.id.raw) (a)")
        }
        a.label = "Phosphor.\(texture.id.raw).a"

        let pingPong = texture.swap != .none
        let b: MTLTexture
        if pingPong {
            guard let madeB = device.makeTexture(descriptor: descriptor) else {
                throw PhosphorRuntimeError.allocationFailed("texture \(texture.id.raw) (b)")
            }
            madeB.label = "Phosphor.\(texture.id.raw).b"
            b = madeB
        } else {
            b = a
        }

        // Honor init action.
        switch texture.initialContents {
        case .zero:
            break  // Storage mode .private + first compute write zero-fills implicitly.

        case .fill:
            // TODO(#52): implement fill via a small init compute or blit-with-color.
            break

        case .image(let file):
            do {
                try seedTextureFromAsset(file: file, into: a, alsoInto: pingPong ? b : nil)
            } catch {
                appendDiagnostic(.missingAsset(name: file, in: texture.id))
            }

        case .noise:
            // TODO(#52): implement noise init.
            break
        }

        return PingPongTexture(pingPong: pingPong, a: a, b: b)
    }

    private func seedTextureFromAsset(
        file: String,
        into primary: MTLTexture,
        alsoInto secondary: MTLTexture?
    ) throws {
        guard let asset = assetData(named: file) else {
            throw PhosphorRuntimeError.assetMissing(name: file)
        }

        let options: [MTKTextureLoader.Option: Any] = [
            .textureStorageMode: NSNumber(value: MTLStorageMode.shared.rawValue),
            .SRGB: NSNumber(value: false)
        ]
        let decoded: MTLTexture
        do {
            decoded = try textureLoader.newTexture(data: asset, options: options)
        } catch {
            Self.logger.error("asset '\(file, privacy: .public)' failed to decode: \(error, privacy: .public)")
            throw PhosphorRuntimeError.assetMissing(name: file)
        }

        guard let queue = device.makeCommandQueue(),
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeBlitCommandEncoder() else {
            throw PhosphorRuntimeError.assetMissing(name: file)
        }
        let copyWidth = min(decoded.width, primary.width)
        let copyHeight = min(decoded.height, primary.height)
        let sourceSize = MTLSize(width: copyWidth, height: copyHeight, depth: 1)
        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        encoder.copy(from: decoded, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: sourceSize,
                     to: primary, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        if let secondary {
            encoder.copy(from: decoded, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: sourceSize,
                         to: secondary, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        }
        encoder.endEncoding()
        commandBuffer.commit()
    }

    /// Looks up asset data, trying the literal name first then the name
    /// without its extension (so kernels can write `file = "screenshot"`
    /// for an asset stored on disk as `screenshot.png`).
    private func assetData(named: String) -> Data? {
        if let asset = assets[named] { return asset.data }
        let stem = (named as NSString).deletingPathExtension
        if stem != named, let asset = assets[stem] { return asset.data }
        return nil
    }

    private func appendDiagnostic(_ diagnostic: PhosphorDiagnostic) {
        diagnostics.append(diagnostic)
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
        case .bgra8Unorm: return .bgra8Unorm
        case .rgba16Float: return .rgba16Float
        case .rgba32Float: return .rgba32Float
        }
    }

    private static func makeFallbackTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false
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
    case assetMissing(name: String)

    public var description: String {
        switch self {
        case .allocationFailed(let what): return "PhosphorRuntime: failed to allocate \(what)"
        case .assetMissing(let name): return "PhosphorRuntime: asset '\(name)' missing or undecodable"
        }
    }
}
