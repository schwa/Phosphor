import Foundation
import PhosphorModel

/// Builds the synthetic `Phosphor.h` content that the runtime prepends to
/// every kernel's source before compilation.
///
/// There is no on-disk `Phosphor.h`. The user writes `#include "Phosphor.h"`
/// in their source as a hint to readers, but the runtime strips it (treats
/// it as a no-op include) when assembling the full compile unit.
///
/// The header declares:
///
/// - Per-pass `Pass_<id>_Textures` and `Pass_<id>_Uniforms` structs. The
///   source assembler inserts `#define Textures Pass_<id>_Textures` /
///   `#define Uniforms Pass_<id>_Uniforms` immediately before each kernel
///   so the user can write `Textures` / `Uniforms` and have it resolve to
///   their pass's type.
/// - `UserUniforms` — auto-generated from the configuration's user-declared
///   uniforms. One per config (not per pass).
///
/// Plus the `metal_stdlib` import and `using namespace metal`.
public enum PhosphorHeader {
    /// Builds the full prelude string for a given configuration.
    public static func source(for config: PhosphorConfiguration) -> String {
        var out = ""
        out += "#include <metal_stdlib>\n"
        out += "using namespace metal;\n\n"
        out += helpersDecl()
        out += "\n"
        out += userUniformsDecl(uniforms: config.uniforms)
        out += "\n"
        for pass in config.passes {
            out += texturesDecl(pass: pass)
            out += "\n"
            out += uniformsDecl(pass: pass)
            out += "\n"
        }
        return out
    }

    /// Mangled name for a pass's `Textures` struct. The source assembler
    /// emits a `#define Textures Pass_<id>_Textures` before each kernel so
    /// authors write `Textures` and get the right type.
    static func passTexturesTypeName(_ pass: Pass) -> String {
        "Pass_\(pass.id.raw)_Textures"
    }

    /// Mangled name for a pass's `Uniforms` struct (which carries the
    /// pass's `Textures` as a nested field).
    static func passUniformsTypeName(_ pass: Pass) -> String {
        "Pass_\(pass.id.raw)_Uniforms"
    }

    /// Auto-generated per-pass `Textures` struct.
    ///
    /// One `texture2d<float, access::XXX>` field per binding, named by the
    /// texture's id. Access qualifier comes straight off the binding.
    /// Empty (no bindings) is legal but useless — every kernel needs at
    /// least one write target.
    static func texturesDecl(pass: Pass) -> String {
        var out = "struct \(passTexturesTypeName(pass)) {\n"
        for binding in pass.textures {
            out += "    texture2d<float, access::\(binding.access.metalQualifier)> \(binding.effectiveName);\n"
        }
        out += "};\n"
        return out
    }

    /// Auto-generated per-pass `Uniforms` struct. Layout must match
    /// ``BuiltinUniforms`` on the Swift side (plus the trailing
    /// `Textures` argument-buffer field).
    static func uniformsDecl(pass: Pass) -> String {
        """
        struct \(passUniformsTypeName(pass)) {
            float time;
            float timeDelta;
            float frame;
            float2 resolution;
            float2 mouse;
            uint mouseButtons;
            uint resized;
            float2 mouseClickOrigin;
            // Audio. Always present; zero-filled when the mic is disabled.
            // waveform: 1024 floats of time-domain samples in [-1, 1].
            // spectrum: 512 floats of linear FFT magnitudes in [0, 1].
            device const float* waveform;
            device const float* spectrum;
            \(passTexturesTypeName(pass)) textures;
        };

        """
    }

    /// Static math helpers + constants, loaded from the bundled
    /// `Resources/Phosphor.h` resource (the single source of truth). Cached
    /// after first read. Falls back to an empty string if the resource is
    /// somehow missing (kernels then lose the helpers but still compile their
    /// own code).
    static func helpersDecl() -> String {
        staticHelperSource
    }

    /// Lazily-loaded, process-cached contents of the static `Phosphor.h`
    /// helper file (the full implementations). ``PhosphorInterface`` derives
    /// the declarations-only view from this. A missing/unreadable resource is
    /// a build error, so it traps rather than silently dropping the helpers.
    public static let staticHelperSource: String = {
        guard let url = Bundle.module.url(forResource: "Phosphor", withExtension: "h") else {
            fatalError("Missing bundled resource Phosphor.h")
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            fatalError("Failed to read Phosphor.h: \(error)")
        }
    }()

    /// Auto-generated `UserUniforms` struct.
    ///
    /// Empty struct (no fields) when the configuration declares no uniforms;
    /// still emitted so kernel signatures don't have to vary.
    static func userUniformsDecl(uniforms: [UniformDecl]) -> String {
        var out = "struct UserUniforms {\n"
        if uniforms.isEmpty {
            out += "    int _unused;\n"
        } else {
            for uniform in uniforms {
                out += "    \(metalType(for: uniform.kind)) \(uniform.name);\n"
            }
        }
        out += "};\n"
        return out
    }

    /// Maps a ``UniformKind`` to its MSL type name.
    static func metalType(for kind: UniformKind) -> String {
        switch kind {
        case .float: return "float"
        case .float2: return "float2"
        case .float3: return "float3"
        case .float4: return "float4"
        case .int: return "int"
        case .bool: return "bool"
        case .color: return "float4"
        }
    }
}

extension TextureAccess {
    /// The MSL access:: token for this binding mode.
    var metalQualifier: String {
        switch self {
        case .read: return "read"
        case .sample: return "sample"
        case .write: return "write"
        case .readWrite: return "read_write"
        }
    }
}
