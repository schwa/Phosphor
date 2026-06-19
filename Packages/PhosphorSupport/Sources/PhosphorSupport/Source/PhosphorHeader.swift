import Foundation

/// Builds the synthetic `Phosphor.h` content that the runtime prepends to
/// every kernel's source before compilation.
///
/// There is no on-disk `Phosphor.h`. The user writes `#include "Phosphor.h"`
/// in their source as a hint to readers, but the runtime strips it (treats
/// it as a no-op include) when assembling the full compile unit.
///
/// The header declares:
///
/// - `Uniforms` — built-in per-frame uniforms.
/// - `ChannelBindings` — auto-generated, sized to the inferred channel count.
/// - `UserUniforms` — auto-generated from the environment's user-declared
///   uniforms.
///
/// Plus the `metal_stdlib` import and `using namespace metal`.
public enum PhosphorHeader {
    /// Builds the full prelude string for a given environment.
    public static func source(for env: PhosphorEnvironment) -> String {
        var out = ""
        out += "#include <metal_stdlib>\n"
        out += "using namespace metal;\n\n"
        out += uniformsDecl()
        out += "\n"
        out += channelBindingsDecl(channelCount: channelCount(for: env))
        out += "\n"
        out += userUniformsDecl(uniforms: env.uniforms)
        return out
    }

    /// Built-in `Uniforms` struct. Layout must match
    /// ``BuiltinUniforms`` on the Swift side.
    static func uniformsDecl() -> String {
        """
        struct Uniforms {
            float time;
            float timeDelta;
            float frame;
            uint channelCount;
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
        };

        """
    }

    /// Auto-generated `ChannelBindings` argument-buffer struct.
    ///
    /// Sized to `channelCount`. Each slot is a `texture2d<float, access::read>`
    /// declared via the `TEXTURE2D` macro from `MetalSprocketsShaders.h`. On
    /// Metal it expands to a real texture handle; on Swift it'd be an
    /// `MTLResourceID` if we ever needed the host-side mirror.
    ///
    /// Empty struct (no slots) is legal — Metal accepts it.
    static func channelBindingsDecl(channelCount: Int) -> String {
        var out = "struct ChannelBindings {\n"
        for index in 0..<channelCount {
            out += "    texture2d<float, access::read> iChannel\(index);\n"
        }
        out += "};\n"
        return out
    }

    /// Auto-generated `UserUniforms` struct.
    ///
    /// Empty struct (no fields) when the environment declares no uniforms;
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
