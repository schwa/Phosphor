import Foundation
import Metal
import MetalSprockets
import Testing
@testable import PhosphorSupport

/// Headless smoke test: runs a single frame of every shipped Examples/*.metal
/// through the runtime to catch front-matter regressions, compile errors,
/// and runtime failures. Doesn't compare pixel output — just asserts the
/// frame completes without throwing.
@Suite("Render smoke test (every Examples/*.metal)")
struct RenderSmokeTests {
    /// `Resources/` symlinks to the repo's top-level `Examples/` directory
    /// and is copied into the test bundle by SwiftPM (see Package.swift).
    /// `Bundle.module.resourceURL` points at `bundle/Contents/Resources/` on
    /// macOS, and SwiftPM's `.copy("Resources")` adds another `Resources/`
    /// inside that.
    static let examplesDirectory: URL = {
        (Bundle.module.resourceURL ?? Bundle.module.bundleURL)
            .appendingPathComponent("Resources")
    }()

    static let exampleNames: [String] = {
        (try? FileManager.default.contentsOfDirectory(at: examplesDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "metal" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
        ?? []
    }()

    @Test("Examples directory exists and is non-empty")
    func examplesExist() {
        #expect(!Self.exampleNames.isEmpty)
    }

    @Test("Every shipped example renders one frame without throwing", arguments: exampleNames)
    @MainActor
    func renderOneFrame(name: String) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw TestSkip.noDevice
        }

        let url = Self.examplesDirectory.appendingPathComponent("\(name).metal")
        let source = try String(contentsOf: url, encoding: .utf8)
        let parsed = ParsedPhosphorSource(source: source)
        guard let environment = parsed.environment else {
            Issue.record("\(name): no front-matter / failed to parse")
            return
        }
        let validationDiagnostics = parsed.diagnostics
        #expect(validationDiagnostics.isEmpty, "\(name) validation diagnostics: \(validationDiagnostics)")

        let runtime = try PhosphorRuntime(device: device, environment: environment, source: parsed.body)
        #expect(runtime.diagnostics.isEmpty, "\(name) compile diagnostics: \(runtime.diagnostics)")

        let size = CGSize(width: 256, height: 256)
        let uniforms = BuiltinUniforms(
            time: 0,
            timeDelta: 0,
            frame: 0,
            resolution: SIMD2<Float>(Float(size.width), Float(size.height))
        )

        let element = PhosphorPipeline(
            runtime: runtime,
            uniforms: uniforms,
            userUniformValues: [:],
            drawableSize: size
        )

        let renderer = try OffscreenRenderer(size: size)
        let rendering = try renderer.render(element)
        #expect(rendering.texture.width == Int(size.width))
        #expect(rendering.texture.height == Int(size.height))
    }
}
