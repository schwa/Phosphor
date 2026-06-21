import Foundation
import Metal

/// The result of compiling a Phosphor source into a live Metal library.
///
/// Compilation is *partial-success*: a structural validation error or a Metal
/// compile error does not throw. Instead the offending step is recorded in
/// ``diagnostics`` and the caller decides what to do. ``library`` and
/// ``passFunctions`` are populated as far as compilation got:
///
/// - Fatal validation error → ``library`` is `nil`, ``passFunctions`` empty.
/// - Library compile error → ``library`` is `nil`, ``passFunctions`` empty,
///   one `.compile` diagnostic attributed to the first enabled pass.
/// - Per-pass function lookup failure → that pass is absent from
///   ``passFunctions`` and gets its own `.compile` diagnostic; other passes
///   still succeed.
public struct CompiledShader: Sendable {
    /// The configuration the compile was driven from.
    public var configuration: PhosphorConfiguration
    /// The compiled library, or `nil` if a fatal/validation/library error
    /// prevented it.
    public var library: MTLLibrary?
    /// The successfully-resolved kernel function for each enabled pass.
    public var passFunctions: [ResourceID: MTLFunction]
    /// Validation + compile diagnostics. May be non-empty even when
    /// ``library`` is present (e.g. a non-fatal missing-asset warning).
    public var diagnostics: [PhosphorDiagnostic]

    /// Whether the shader can be rendered: a library plus a function for every
    /// enabled pass.
    public var isRenderable: Bool {
        guard library != nil else { return false }
        return configuration.passes
            .filter(\.enabled)
            .allSatisfy { passFunctions[$0.id] != nil }
    }

    /// The first compile error's raw message, if any. Useful for feeding a
    /// retry prompt to a generator.
    public var firstCompileError: String? {
        for case .compile(let error) in diagnostics {
            return error.rawError
        }
        return nil
    }
}

/// Single entry point that turns a Phosphor source into a ``CompiledShader``.
///
/// Internally runs validate → assemble → `makeLibrary` → per-pass
/// `makeFunction`. Replaces the hand-stitched compile dance that
/// ``PhosphorRuntime`` and the shader generator each used to repeat.
public enum ShaderCompiler {
    /// Compiles an already-parsed source.
    ///
    /// The parse step already validated the configuration, so validation is
    /// *not* re-run here: ``ParsedPhosphorSource/diagnostics`` (front-matter
    /// parse + validation) is authoritative and carried straight through. This
    /// is the single parse → validate → compile path; prefer it over
    /// ``compile(configuration:userSource:device:)``.
    public static func compile(parsed: ParsedPhosphorSource, device: MTLDevice) -> CompiledShader {
        compile(
            configuration: parsed.configuration,
            userSource: parsed.body,
            device: device,
            preValidatedDiagnostics: parsed.diagnostics
        )
    }

    /// Compiles a configuration plus its user Metal source, validating the
    /// configuration itself.
    ///
    /// Callers that already hold a ``ParsedPhosphorSource`` should use
    /// ``compile(parsed:device:)`` instead, which avoids re-validating.
    public static func compile(
        configuration: PhosphorConfiguration,
        userSource: String,
        device: MTLDevice
    ) -> CompiledShader {
        compile(
            configuration: configuration,
            userSource: userSource,
            device: device,
            preValidatedDiagnostics: validate(configuration)
        )
    }

    private static func compile(
        configuration: PhosphorConfiguration,
        userSource: String,
        device: MTLDevice,
        preValidatedDiagnostics: [PhosphorDiagnostic]
    ) -> CompiledShader {
        var diagnostics = preValidatedDiagnostics

        if diagnostics.contains(where: \.isFatal) {
            return CompiledShader(
                configuration: configuration,
                library: nil,
                passFunctions: [:],
                diagnostics: diagnostics
            )
        }

        let compiler = PhosphorCompiler(device: device)
        let library: MTLLibrary
        do {
            library = try compiler.compileLibrary(configuration: configuration, userSource: userSource)
        } catch {
            let attributedTo = configuration.passes.first(where: \.enabled)?.id ?? "library"
            diagnostics.append(.compile(.init(passID: attributedTo, rawError: "\(error)")))
            return CompiledShader(
                configuration: configuration,
                library: nil,
                passFunctions: [:],
                diagnostics: diagnostics
            )
        }

        var functions: [ResourceID: MTLFunction] = [:]
        for pass in configuration.passes where pass.enabled {
            do {
                functions[pass.id] = try compiler.makeFunction(library: library, for: pass.id)
            } catch {
                diagnostics.append(.compile(.init(passID: pass.id, rawError: "\(error)")))
            }
        }

        return CompiledShader(
            configuration: configuration,
            library: library,
            passFunctions: functions,
            diagnostics: diagnostics
        )
    }
}
