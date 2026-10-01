import AVFoundation
import CoreVideo
import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
import PhosphorRuntime

/// Renders a shader over a time range and encodes the frames to a movie.
///
/// Rendering is offline and deterministic: frame *n* is always rendered at
/// `startTime + n / frameRate` with `frame = n`, regardless of how fast the
/// machine encodes. Two exports of the same shader produce the same footage,
/// which real-time capture can't promise.
///
/// The exporter builds its own ``PhosphorRuntime``, so exporting doesn't
/// disturb the live preview's feedback state (or vice versa).
public struct VideoExporter: Sendable {
    public struct Settings: Hashable, Sendable {
        /// Pixel size of the exported movie.
        public var size: CGSize
        /// Frames per second, and the clock the shader is stepped at.
        public var frameRate: Int
        /// Shader time of the first frame.
        public var startTime: Double
        /// Duration of the exported range, in shader time.
        public var duration: Double
        public var codec: AVVideoCodecType

        public init(
            size: CGSize = CGSize(width: 1_920, height: 1_080),
            frameRate: Int = 60,
            startTime: Double = 0,
            duration: Double = 5,
            codec: AVVideoCodecType = .h264
        ) {
            self.size = size
            self.frameRate = frameRate
            self.startTime = startTime
            self.duration = duration
            self.codec = codec
        }

        /// Number of frames the settings describe. At least one.
        public var frameCount: Int {
            max(1, Int((duration * Double(frameRate)).rounded()))
        }
    }

    public enum ExportError: Error, Sendable {
        case noMetalDevice
        case textureCacheFailed
        case pixelBufferPoolUnavailable
        case pixelBufferAllocationFailed
        case textureCreationFailed
        case writerFailed(String)
    }

    public init() {}

    /// Renders `parsed` over the settings' time range and writes a movie to
    /// `url`, replacing anything already there.
    ///
    /// - Parameter progress: called on each encoded frame with a value in
    ///   `0...1`. Cancel by cancelling the enclosing task.
    public func export(
        parsed: ParsedPhosphorSource,
        assets: [String: PhosphorAsset] = [:],
        uniformValues: [String: UniformValue] = [:],
        to url: URL,
        settings: Settings,
        progress: @Sendable (Double) -> Void = { _ in }
    ) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.noMetalDevice }
        let width = max(1, Int(settings.size.width))
        let height = max(1, Int(settings.size.height))

        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: settings.codec,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height
            ]
        )
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        guard writer.canAdd(input) else { throw ExportError.writerFailed("can't add video input") }
        writer.add(input)
        guard writer.startWriting() else {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "startWriting failed")
        }
        writer.startSession(atSourceTime: .zero)

        // Rendering straight into the pixel buffer's IOSurface avoids a
        // texture-to-CPU-to-buffer round trip per frame.
        var cacheOut: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cacheOut) == kCVReturnSuccess,
              let textureCache = cacheOut else {
            throw ExportError.textureCacheFailed
        }

        let runtime = PhosphorRuntime(
            configuration: parsed.configuration,
            source: parsed.body,
            assets: assets
        )
        let renderer = try PhosphorRenderer(device: device)
        guard let queue = device.makeMTL4CommandQueue() else { throw ExportError.noMetalDevice }
        let allocatorDescriptor = MTL4CommandAllocatorDescriptor()
        guard let allocator = try? device.makeCommandAllocator(descriptor: allocatorDescriptor),
              let commandBuffer = device.makeCommandBuffer() else {
            throw ExportError.noMetalDevice
        }

        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        let step = 1.0 / Double(settings.frameRate)

        do {
            for index in 0..<settings.frameCount {
                try Task.checkCancellation()
                try await waitUntilReady(input)

                guard let pool = adaptor.pixelBufferPool else { throw ExportError.pixelBufferPoolUnavailable }
                var bufferOut: CVPixelBuffer?
                guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &bufferOut) == kCVReturnSuccess,
                      let pixelBuffer = bufferOut else {
                    throw ExportError.pixelBufferAllocationFailed
                }
                let target = try Self.texture(for: pixelBuffer, cache: textureCache, width: width, height: height)

                let time = settings.startTime + Double(index) * step
                let uniforms = BuiltinUniforms(
                    time: Float(time),
                    timeDelta: Float(step),
                    frame: Float(index),
                    resolution: SIMD2<Float>(Float(width), Float(height))
                )

                allocator.reset()
                commandBuffer.beginCommandBuffer(allocator: allocator)
                try renderer.render(
                    runtime: runtime,
                    into: commandBuffer,
                    targetTexture: target,
                    drawableSize: CGSize(width: width, height: height),
                    builtin: uniforms,
                    userUniformValues: uniformValues
                )
                commandBuffer.endCommandBuffer()
                await withCheckedContinuation { continuation in
                    let options = MTL4CommitOptions()
                    options.addFeedbackHandler { _ in continuation.resume() }
                    queue.commit([commandBuffer], options: options)
                }

                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
                    throw ExportError.writerFailed(
                        writer.error?.localizedDescription ?? "append failed at frame \(index)"
                    )
                }
                progress(Double(index + 1) / Double(settings.frameCount))
            }
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }

        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw ExportError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    /// Wraps a pixel buffer's IOSurface as a render target.
    private static func texture(
        for pixelBuffer: CVPixelBuffer,
        cache: CVMetalTextureCache,
        width: Int,
        height: Int
    ) throws -> MTLTexture {
        var metalTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil,
            cache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width,
            height,
            0,
            &metalTextureOut
        )
        guard status == kCVReturnSuccess,
              let metalTexture = metalTextureOut,
              let texture = CVMetalTextureGetTexture(metalTexture) else {
            throw ExportError.textureCreationFailed
        }
        return texture
    }

    /// Suspends until the writer input can take more frames. The encoder is
    /// slower than the renderer, so without this the whole movie would be
    /// buffered in memory.
    private func waitUntilReady(_ input: AVAssetWriterInput) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
