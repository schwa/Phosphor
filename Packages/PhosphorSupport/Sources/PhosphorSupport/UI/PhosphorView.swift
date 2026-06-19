import Foundation
import Metal
import MetalSprockets
import MetalSprocketsUI
import SwiftUI

/// SwiftUI surface for a Phosphor 2 effect.
///
/// Owns a ``PhosphorRuntime``, recompiling it whenever `environment` or
/// `source` change. Drives the `RenderView` with per-frame ``BuiltinUniforms``.
///
/// Renders host controls for each ``UniformDecl`` declared by the environment
/// (`PhosphorView` keeps a `[String: UniformValue]` of live values, seeded
/// from the declared defaults; each frame the runtime packs them into the
/// user-uniforms buffer).
public struct PhosphorView: View {
    public let environment: PhosphorEnvironment
    public let source: String
    public let frontMatterDiagnostics: [PhosphorDiagnostic]

    @State private var runtime: PhosphorRuntime?
    @State private var initError: Error?
    @State private var uniformValues: [String: UniformValue] = [:]
    @AppStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @Environment(\.audioCapture) private var audioCapture

    // Mouse state, in pixel coordinates (matching uniforms.resolution).
    // Updated by gestures on the RenderView; passed into BuiltinUniforms
    // each frame.
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero
    /// Logical view size (in points). Combined with the drawable size to
    /// convert mouse coordinates from points to pixels.
    @State private var viewSize: CGSize = .zero

    public init(environment: PhosphorEnvironment, source: String) {
        self.environment = environment
        self.source = source
        self.frontMatterDiagnostics = []
    }

    /// Convenience: parses front-matter from `source`, then constructs as
    /// usual. If the source has no front-matter or parsing fails, returns
    /// `nil`; the parsed diagnostics flow through `parsed.diagnostics`.
    public init?(source: String) {
        self.init(parsed: ParsedPhosphorSource(source: source))
    }

    /// Construct from an already-parsed source, e.g. when the caller wants to
    /// inspect diagnostics or environment before deciding to render.
    public init?(parsed: ParsedPhosphorSource) {
        guard let environment = parsed.environment else { return nil }
        self.environment = environment
        self.source = parsed.body
        self.frontMatterDiagnostics = parsed.diagnostics
    }

    public var body: some View {
        ZStack {
            if let runtime {
                RenderView { context, drawableSize in
                    let uniforms = BuiltinUniforms(
                        time: context.frameUniforms.time,
                        timeDelta: Float(context.frameUniforms.deltaTime),
                        frame: Float(context.frameUniforms.index),
                        resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                        mouse: mousePosition,
                        mouseButtons: mouseButtons,
                        mouseClickOrigin: mouseClickOrigin
                    )
                    PhosphorPipeline(
                        runtime: runtime,
                        uniforms: uniforms,
                        userUniformValues: uniformValues,
                        drawableSize: drawableSize
                    )
                }
                .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                    viewSize = newSize
                }
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        mousePosition = pixelCoordinate(from: point)
                    case .ended:
                        break
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            mousePosition = pixelCoordinate(from: value.location)
                            if mouseButtons & 0b1 == 0 {
                                // First frame of the press: record click origin.
                                mouseClickOrigin = pixelCoordinate(from: value.startLocation)
                            }
                            mouseButtons |= 0b1
                        }
                        .onEnded { _ in
                            mouseButtons &= ~0b1
                        }
                )
                .overlay(alignment: .topLeading) {
                    diagnosticsOverlay(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
                }
                .overlay(alignment: .topTrailing) {
                    uniformsOverlay
                }
            } else if let initError {
                errorView(message: "\(initError)")
            } else {
                Color.black
            }
        }
        .task(id: SourceKey(environment: environment, source: source)) {
            await updateRuntime()
            uniformValues = UserUniformsLayout.defaultsDictionary(environment.uniforms)
        }
    }

    // MARK: - Uniforms panel

    @ViewBuilder
    private var uniformsOverlay: some View {
        if !environment.uniforms.isEmpty, showUniformsPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text("Uniforms").font(.caption).bold().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background { Color.black.opacity(0.6) }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(environment.uniforms, id: \.name) { uniform in
                        UniformControl(
                            uniform: uniform,
                            value: Binding(
                                get: { uniformValues[uniform.name] ?? uniform.defaultValue },
                                set: { uniformValues[uniform.name] = $0 }
                            )
                        )
                    }
                }
                .padding(8)
                .background { Color.black.opacity(0.5) }
                .foregroundStyle(.white)
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 320)
            .padding(8)
        }
    }

    /// Converts a point in PhosphorView's coordinate space to pixel
    /// coordinates matching `uniforms.resolution`. Uses the cached `viewSize`
    /// (in points) and assumes the drawable's aspect matches the view.
    private func pixelCoordinate(from point: CGPoint) -> SIMD2<Float> {
        guard viewSize.width > 0, viewSize.height > 0,
              let drawableSize = runtime?.currentDrawableSize,
              drawableSize.width > 0, drawableSize.height > 0 else {
            return SIMD2<Float>(Float(point.x), Float(point.y))
        }
        let scaleX = Float(drawableSize.width / viewSize.width)
        let scaleY = Float(drawableSize.height / viewSize.height)
        return SIMD2<Float>(Float(point.x) * scaleX, Float(point.y) * scaleY)
    }

    @MainActor
    private func updateRuntime() async {
        do {
            if let runtime {
                try runtime.update(environment: environment, source: source)
            } else {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    initError = NSError(domain: "PhosphorView", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "No Metal device available"
                    ])
                    return
                }
                let newRuntime = try PhosphorRuntime(device: device, environment: environment, source: source)
                newRuntime.audioCapture = audioCapture
                runtime = newRuntime
            }
        } catch {
            initError = error
        }
    }

    // MARK: - Diagnostics overlay

    @ViewBuilder
    private func diagnosticsOverlay(diagnostics: [PhosphorDiagnostic]) -> some View {
        if !diagnostics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(verbatim: diagnosticString(diagnostic))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.white)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .frame(maxWidth: 720, maxHeight: 400)
            .padding(8)
        }
    }

    private func diagnosticString(_ diagnostic: PhosphorDiagnostic) -> String {
        switch diagnostic {
        case .frontMatterParse(let msg, let line):
            return "frontmatter: \(msg)\(line.map { " (line \($0))" } ?? "")"
        case .unknownResource(let id, let context):
            return "unknown resource '\(id)' in \(context)"
        case .duplicateResource(let id):
            return "duplicate resource '\(id)'"
        case .duplicatePass(let id):
            return "duplicate pass '\(id)'"
        case .unknownChannelName(let name, let pass):
            return "unknown channel '\(name)' in pass '\(pass)'"
        case .channelOutOfRange(let name, let inferred):
            return "channel '\(name)' out of range (inferred \(inferred))"
        case .duplicateBinding(let name, let pass):
            return "duplicate binding '\(name)' in pass '\(pass)'"
        case .readWriteHazard(let pass, let resource):
            return "read/write hazard: pass '\(pass)' reads + writes '\(resource)'"
        case .missingOutput(let id):
            return "missing output resource '\(id)'"
        case .compile(let error):
            return "compile error in '\(error.passID)':\n\(error.rawError)"
        }
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        ContentUnavailableView {
            Label("Phosphor Error", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .font(.system(.body, design: .monospaced))
        }
    }
}

private struct SourceKey: Hashable {
    var environment: PhosphorEnvironment
    var source: String
}
