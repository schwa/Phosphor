import Foundation
import Metal
import MetalSprockets
import MetalSprocketsUI
import SwiftUI

/// SwiftUI surface for a Phosphor 2 effect.
///
/// Owns a ``PhosphorRuntime``, recompiling it whenever `environment` or
/// `source` change. Drives the `RenderView` with per-frame ``BuiltinUniforms``.
public struct PhosphorView: View {
    public let environment: PhosphorEnvironment
    public let source: String

    @State private var runtime: PhosphorRuntime?
    @State private var initError: Error?

    public init(environment: PhosphorEnvironment, source: String) {
        self.environment = environment
        self.source = source
    }

    public var body: some View {
        ZStack {
            if let runtime {
                RenderView { context, drawableSize in
                    let uniforms = BuiltinUniforms(
                        time: context.frameUniforms.time,
                        timeDelta: Float(context.frameUniforms.deltaTime),
                        frame: Float(context.frameUniforms.index),
                        resolution: SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))
                    )
                    PhosphorPipeline(
                        runtime: runtime,
                        uniforms: uniforms,
                        drawableSize: drawableSize
                    )
                }
                .overlay(alignment: .topLeading) {
                    diagnosticsOverlay(diagnostics: runtime.diagnostics)
                }
            } else if let initError {
                errorView(message: "\(initError)")
            } else {
                Color.black
            }
        }
        .task(id: SourceKey(environment: environment, source: source)) {
            await updateRuntime()
        }
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
                runtime = try PhosphorRuntime(device: device, environment: environment, source: source)
            }
        } catch {
            initError = error
        }
    }

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
