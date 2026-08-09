import AVFoundation
import Foundation
import Metal
import PhosphorCompile
import PhosphorModel
import PhosphorVideo
import Testing

@Suite("Video export")
struct VideoExporterTests {
    /// A shader whose output colour is a known function of time, so a decoded
    /// frame can be checked against the time it claims to represent.
    static let rampShader = """
    /* phosphor:environment
    output = "image"

    [[textures]]
    id = "image"

    [[passes]]
    id = "image"
    textures = [{ id = "image", access = "write" }]
    */

    uint2 gid [[thread_position_in_grid]];

    kernel void image(
        device const Uniforms&     uniforms     [[buffer(0)]],
        device const UserUniforms& userUniforms [[buffer(1)]])
    {
        uniforms.textures.image.write(float4(uniforms.time, 0.0, 0.0, 1.0), gid);
    }
    """

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("phosphor-export-\(UUID().uuidString).mov")
    }

    // MARK: Settings

    @Test("Frame count follows duration and frame rate")
    func frameCount() {
        #expect(VideoExporter.Settings(frameRate: 60, duration: 2).frameCount == 120)
        #expect(VideoExporter.Settings(frameRate: 30, duration: 0.5).frameCount == 15)
    }

    /// A zero-length export would produce a movie with no frames, which most
    /// players treat as corrupt.
    @Test("A degenerate duration still yields one frame")
    func frameCountFloor() {
        #expect(VideoExporter.Settings(frameRate: 60, duration: 0).frameCount == 1)
    }

    // MARK: Export

    @Test("Exports a movie with the requested size, frame count and duration")
    func exportsMovie() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let settings = VideoExporter.Settings(
            size: CGSize(width: 128, height: 64),
            frameRate: 30,
            duration: 0.5
        )
        try await VideoExporter().export(
            parsed: ParsedPhosphorSource(source: Self.rampShader),
            to: url,
            settings: settings
        )

        #expect(FileManager.default.fileExists(atPath: url.path))
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size == CGSize(width: 128, height: 64))

        let duration = try await asset.load(.duration).seconds
        #expect(abs(duration - 0.5) < 0.05, "duration was \(duration)")
    }

    @Test("Progress runs from a first frame to exactly 1")
    func reportsProgress() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let collector = ProgressCollector()
        try await VideoExporter().export(
            parsed: ParsedPhosphorSource(source: Self.rampShader),
            to: url,
            settings: VideoExporter.Settings(
                size: CGSize(width: 64, height: 64),
                frameRate: 10,
                duration: 0.5
            )
        ) { collector.record($0) }

        let values = collector.values
        #expect(values.count == 5)
        #expect(values.last == 1.0)
        #expect(values == values.sorted())
    }

    /// The point of offline rendering: the same settings must produce the same
    /// footage, no matter how fast the machine encoded it. Compared as decoded
    /// pixels rather than file bytes — the QuickTime container carries a
    /// creation date, so the files themselves never match.
    @Test("Two exports of the same shader produce identical frames")
    func isDeterministic() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let first = temporaryURL()
        let second = temporaryURL()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let settings = VideoExporter.Settings(
            size: CGSize(width: 64, height: 64),
            frameRate: 10,
            duration: 0.3
        )
        let parsed = ParsedPhosphorSource(source: Self.rampShader)
        let exporter = VideoExporter()
        try await exporter.export(parsed: parsed, to: first, settings: settings)
        try await exporter.export(parsed: parsed, to: second, settings: settings)

        for frame in [0, 2] {
            let time = CMTime(value: CMTimeValue(frame), timescale: 10)
            let left = try await pixels(of: first, at: time)
            let right = try await pixels(of: second, at: time)
            #expect(left == right, "frame \(frame) differed between exports")
        }
    }

    /// Decoded RGBA bytes of the frame at `time`.
    private func pixels(of url: URL, at time: CMTime) async throws -> [UInt8] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: time)
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try #require(CGContext(
            data: &buffer,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    /// Frame n must be rendered at startTime + n / frameRate. Sampling the
    /// last frame of a time-ramped shader checks the shader clock actually
    /// advanced, rather than every frame being rendered at t = 0.
    @Test("Shader time advances across the exported range")
    func advancesShaderTime() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        // 10 fps for 1s: the last frame is t = 0.9, so red should be ~0.9.
        try await VideoExporter().export(
            parsed: ParsedPhosphorSource(source: Self.rampShader),
            to: url,
            settings: VideoExporter.Settings(
                size: CGSize(width: 64, height: 64),
                frameRate: 10,
                duration: 1.0
            )
        )

        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let firstRed = try await red(of: generator, at: CMTime(value: 0, timescale: 10))
        let lastRed = try await red(of: generator, at: CMTime(value: 9, timescale: 10))
        #expect(firstRed < 0.1, "first frame red was \(firstRed)")
        #expect(lastRed > 0.7, "last frame red was \(lastRed)")
    }

    /// Mean red channel of the frame at `time`, in 0...1. Lossy compression
    /// means this is approximate, hence the loose bounds at the call sites.
    private func red(of generator: AVAssetImageGenerator, at time: CMTime) async throws -> Double {
        let (image, _) = try await generator.image(at: time)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let total = stride(from: 0, to: pixels.count, by: 4).reduce(0.0) { sum, index in
            sum + Double(pixels[index])
        }
        return total / Double(width * height) / 255.0
    }
}

/// Collects progress callbacks, which arrive from the exporter's task.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ value: Double) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
