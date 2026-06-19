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
    /// External pause/play state. When `true`, the kernel sees frozen time
    /// and frame values. Optional so existing call sites (and the smoke
    /// tests) keep working without an explicit binding.
    let isPausedExternally: Binding<Bool>?
    /// External reset signal. Each new value triggers a one-shot reset.
    let resetSignal: Int

    @State private var runtime: PhosphorRuntime?
    @State private var initError: Error?
    @State private var uniformValues: [String: UniformValue] = [:]
    @AppStorage("phosphor.ui.showUniformsPanel") private var showUniformsPanel: Bool = true
    @Environment(\.audioCapture) private var audioCapture

    /// Reference wall-clock time used as t=0 (subtracted from the renderer's
    /// time to get the kernel's time). Updated on reset.
    @State private var timeBase: Float = 0
    /// Reference frame index.
    @State private var frameBase: UInt32 = 0
    /// Snapshot of (time, frame) emitted while paused. Captured from the
    /// renderer the moment the user pauses.
    @State private var pausedSnapshot: (time: Float, frame: Float)?
    /// On the next frame, pull a fresh snapshot from the live values. Set when
    /// the user pauses; cleared once the snapshot is captured.
    @State private var capturePauseSnapshot: Bool = false
    /// On the next frame, set timeBase/frameBase = live values. Set on reset
    /// or resume; cleared once applied.
    @State private var rebaseRequested: Bool = false

    // Mouse state, in pixel coordinates (matching uniforms.resolution).
    // Updated by gestures on the RenderView; passed into BuiltinUniforms
    // each frame.
    @State private var mousePosition: SIMD2<Float> = .zero
    @State private var mouseButtons: UInt32 = 0
    @State private var mouseClickOrigin: SIMD2<Float> = .zero
    /// Logical view size (in points). Combined with the drawable size to
    /// convert mouse coordinates from points to pixels.
    @State private var viewSize: CGSize = .zero

    public init(
        environment: PhosphorEnvironment,
        source: String,
        isPaused: Binding<Bool>? = nil,
        resetSignal: Int = 0
    ) {
        self.environment = environment
        self.source = source
        self.frontMatterDiagnostics = []
        self.isPausedExternally = isPaused
        self.resetSignal = resetSignal
    }

    public init?(source: String, isPaused: Binding<Bool>? = nil, resetSignal: Int = 0) {
        self.init(parsed: ParsedPhosphorSource(source: source), isPaused: isPaused, resetSignal: resetSignal)
    }

    public init?(parsed: ParsedPhosphorSource, isPaused: Binding<Bool>? = nil, resetSignal: Int = 0) {
        guard let environment = parsed.environment else { return nil }
        self.environment = environment
        self.source = parsed.body
        self.frontMatterDiagnostics = parsed.diagnostics
        self.isPausedExternally = isPaused
        self.resetSignal = resetSignal
    }

    public var body: some View {
        ZStack {
            if let runtime {
                RenderView { context, drawableSize in
                    PhosphorPipeline(
                        runtime: runtime,
                        uniforms: buildUniforms(context: context, drawableSize: drawableSize),
                        userUniformValues: uniformValues,
                        drawableSize: drawableSize
                    )
                    .onWorkloadEnter { _ in
                        applyPlaybackSideEffects(context: context)
                    }
                }
                .onGeometryChange(for: CGSize.self, of: \.size) { newSize in
                    viewSize = newSize
                }
                .onChange(of: isPausedExternally?.wrappedValue ?? false) { _, newValue in
                    if newValue {
                        capturePauseSnapshot = true
                    } else {
                        pausedSnapshot = nil
                        rebaseRequested = true
                    }
                }
                .onChange(of: resetSignal) { _, _ in
                    rebaseRequested = true
                    pausedSnapshot = nil
                    capturePauseSnapshot = false
                    runtime.signalReset()
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
                    DiagnosticsOverlay(diagnostics: frontMatterDiagnostics + runtime.diagnostics)
                }
                .overlay(alignment: .topTrailing) {
                    UniformsOverlay(
                        uniforms: environment.uniforms,
                        showPanel: showUniformsPanel,
                        uniformValues: $uniformValues
                    )
                }
            } else if let initError {
                PhosphorErrorView(message: "\(initError)")
            } else {
                Color.black
            }
        }
        .task(id: SourceKey(environment: environment, source: source)) {
            await updateRuntime()
            uniformValues = UserUniformsLayout.defaultsDictionary(environment.uniforms)
        }
    }

    /// Converts a point in PhosphorView's coordinate space to pixel
    /// coordinates matching `uniforms.resolution`. Uses the cached `viewSize`
    /// (in points) and assumes the drawable's aspect matches the view.
    /// Builds the per-frame `BuiltinUniforms`, applying pause/rebase.
    private func buildUniforms(context: RenderViewContext, drawableSize: CGSize) -> BuiltinUniforms {
        let kernelTime: Float
        let kernelFrame: Float
        let kernelDelta: Float
        if let paused = pausedSnapshot {
            kernelTime = paused.time
            kernelFrame = paused.frame
            kernelDelta = 0
        } else {
            kernelTime = context.frameUniforms.time - timeBase
            kernelFrame = Float(context.frameUniforms.index &- frameBase)
            kernelDelta = Float(context.frameUniforms.deltaTime)
        }
        return BuiltinUniforms(
            time: kernelTime,
            timeDelta: kernelDelta,
            frame: kernelFrame,
            resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
            mouse: mousePosition,
            mouseButtons: mouseButtons,
            mouseClickOrigin: mouseClickOrigin
        )
    }

    /// Per-frame state mutation triggered from `.onWorkloadEnter`. Captures
    /// the pause snapshot if requested, and rebases timeBase/frameBase to
    /// the renderer's current values on resume / reset.
    private func applyPlaybackSideEffects(context: RenderViewContext) {
        if capturePauseSnapshot {
            let liveTime = context.frameUniforms.time - timeBase
            let liveFrame = Float(context.frameUniforms.index &- frameBase)
            pausedSnapshot = (time: liveTime, frame: liveFrame)
            capturePauseSnapshot = false
        }
        if rebaseRequested {
            timeBase = context.frameUniforms.time
            frameBase = context.frameUniforms.index
            rebaseRequested = false
        }
    }

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
    private func updateRuntime() {
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
}

/// Translucent panel listing every declared user-uniform with live controls.
/// Hides itself when the environment declares no uniforms.
private struct UniformsOverlay: View {
    let uniforms: [UniformDecl]
    let showPanel: Bool
    @Binding var uniformValues: [String: UniformValue]

    var body: some View {
        if !uniforms.isEmpty, showPanel {
            VStack(alignment: .leading, spacing: 0) {
                Text("Uniforms").font(.caption).bold().foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background { Color.black.opacity(0.6) }

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(uniforms, id: \.name) { uniform in
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
}

/// Top-leading overlay listing front-matter / validation / compile
/// diagnostics for the current document. Renders nothing when empty.
private struct DiagnosticsOverlay: View {
    let diagnostics: [PhosphorDiagnostic]

    var body: some View {
        if !diagnostics.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                        Text(verbatim: Self.diagnosticString(diagnostic))
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

    private static func diagnosticString(_ diagnostic: PhosphorDiagnostic) -> String {
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
}

/// Shown when ``PhosphorView`` failed to initialize its Metal runtime
/// (no GPU, allocation failure, etc.).
private struct PhosphorErrorView: View {
    let message: String

    var body: some View {
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

// MARK: - Previews

#Preview("Error") {
    PhosphorErrorView(message: "No Metal device available")
        .frame(width: 480, height: 240)
}

#Preview("Diagnostics") {
    DiagnosticsOverlay(diagnostics: [
        .missingOutput("image"),
        .duplicatePass("render")
    ])
    .frame(width: 480, height: 240)
}
