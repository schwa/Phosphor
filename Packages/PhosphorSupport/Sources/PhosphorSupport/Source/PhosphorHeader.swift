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

    /// Math helpers + constants ported from Phosphor 1's Support.h. Every
    /// kernel sees these; the Metal compiler dead-codes unused functions.
    static func helpersDecl() -> String {
        """
        // Constants
        constant float PI = 3.141592653589793;
        constant float PI2 = PI * 2.0;

        // GLSL-style type aliases for ports from Shadertoy/GLSL shaders.
        typedef float2 vec2;
        typedef float3 vec3;
        typedef float4 vec4;

        // Magic constant used by some 4D simplex-noise ports.
        #define F4 0.309016994374947451

        // 2D rotation matrix.
        inline float2x2 rotate2D(float angle) {
            float c = cos(angle);
            float s = sin(angle);
            return float2x2(c, -s, s, c);
        }

        // 3D rotation matrix around an arbitrary axis.
        inline float3x3 rotate3D(float angle, float3 axis) {
            float3 a = normalize(axis);
            float s = sin(angle);
            float c = cos(angle);
            float r = 1.0 - c;
            return float3x3(
                a.x * a.x * r + c,
                a.y * a.x * r + a.z * s,
                a.z * a.x * r - a.y * s,
                a.x * a.y * r - a.z * s,
                a.y * a.y * r + c,
                a.z * a.y * r + a.x * s,
                a.x * a.z * r + a.y * s,
                a.y * a.z * r - a.x * s,
                a.z * a.z * r + c
            );
        }

        // Fract-of-sin noise (classic GLSL trick). Cheap pseudo-random.
        inline float fsnoise(float2 c) {
            return fract(sin(dot(c, float2(12.9898, 78.233))) * 43758.5453);
        }

        // Lower-precision variant friendlier to non-fp64 hardware.
        inline float fsnoiseDigits(float2 c) {
            return fract(sin(dot(c, float2(0.129898, 0.78233))) * 437.585453);
        }

        // HSV -> RGB conversion.
        inline float3 hsv(float h, float s, float v) {
            float4 t = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(float3(h) + t.xyz) * 6.0 - float3(t.w));
            return v * mix(float3(t.x), clamp(p - float3(t.x), 0.0, 1.0), s);
        }

        // 2D Simplex noise. Output range roughly [-1, 1].
        inline float snoise2D(float2 v) {
            const float4 C = float4(0.211324865405187, 0.366025403784439,
                                    -0.577350269189626, 0.024390243902439);
            float2 i  = floor(v + dot(v, C.yy));
            float2 x0 = v - i + dot(i, C.xx);
            float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
            float4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = fmod(i, 289.0);
            float3 p = fmod((i.y + float3(0.0, i1.y, 1.0)) * 289.0 + i.x + float3(0.0, i1.x, 1.0), 289.0);
            float3 m = max(0.5 - float3(dot(x0,x0), dot(x12.xy,x12.xy), dot(x12.zw,x12.zw)), 0.0);
            m = m*m; m = m*m;
            float3 x = 2.0 * fract(p * C.www) - 1.0;
            float3 h = abs(x) - 0.5;
            float3 ox = floor(x + 0.5);
            float3 a0 = x - ox;
            m *= 1.79284291400159 - 0.85373472095314 * (a0*a0 + h*h);
            float3 g;
            g.x  = a0.x  * x0.x  + h.x  * x0.y;
            g.yz = a0.yz * x12.xz + h.yz * x12.yw;
            return 130.0 * dot(m, g);
        }

        // 3D Simplex noise.
        inline float snoise3D(float3 v) {
            const float2 C = float2(1.0/6.0, 1.0/3.0);
            const float4 D = float4(0.0, 0.5, 1.0, 2.0);
            float3 i  = floor(v + dot(v, C.yyy));
            float3 x0 = v - i + dot(i, C.xxx);
            float3 g = step(x0.yzx, x0.xyz);
            float3 l = 1.0 - g;
            float3 i1 = min(g.xyz, l.zxy);
            float3 i2 = max(g.xyz, l.zxy);
            float3 x1 = x0 - i1 + C.xxx;
            float3 x2 = x0 - i2 + C.yyy;
            float3 x3 = x0 - D.yyy;
            i = fmod(i, 289.0);
            float4 p = fmod((i.z + float4(0.0, i1.z, i2.z, 1.0)) * 289.0 +
                            (i.y + float4(0.0, i1.y, i2.y, 1.0)) * 17.0 +
                            (i.x + float4(0.0, i1.x, i2.x, 1.0)), 289.0);
            float n_ = 0.142857142857;
            float3 ns = n_ * D.wyz - D.xzx;
            float4 j = p - 49.0 * floor(p * ns.z * ns.z);
            float4 x_ = floor(j * ns.z);
            float4 y_ = floor(j - 7.0 * x_);
            float4 x = x_ * ns.x + ns.yyyy;
            float4 y = y_ * ns.x + ns.yyyy;
            float4 h = 1.0 - abs(x) - abs(y);
            float4 b0 = float4(x.xy, y.xy);
            float4 b1 = float4(x.zw, y.zw);
            float4 s0 = floor(b0) * 2.0 + 1.0;
            float4 s1 = floor(b1) * 2.0 + 1.0;
            float4 sh = -step(h, float4(0.0));
            float4 a0 = b0.xzyw + s0.xzyw * sh.xxyy;
            float4 a1 = b1.xzyw + s1.xzyw * sh.zzww;
            float3 p0 = float3(a0.xy, h.x);
            float3 p1 = float3(a0.zw, h.y);
            float3 p2 = float3(a1.xy, h.z);
            float3 p3 = float3(a1.zw, h.w);
            float4 norm = 1.79284291400159 - 0.85373472095314 *
                          float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3));
            p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
            float4 m = max(0.6 - float4(dot(x0,x0), dot(x1,x1), dot(x2,x2), dot(x3,x3)), 0.0);
            m = m * m;
            return 42.0 * dot(m*m, float4(dot(p0,x0), dot(p1,x1), dot(p2,x2), dot(p3,x3)));
        }

        // 4D Simplex noise.
        inline float snoise4D(float4 v) {
            const float4 C = float4(0.138196601125011, 0.276393202250021,
                                    0.414589803375032, -0.447213595499958);
            float4 i  = floor(v + dot(v, float4(F4)));
            float4 x0 = v - i + dot(i, C.xxxx);
            float4 i0;
            float3 isX = step(x0.yzw, x0.xxx);
            float3 isYZ = step(x0.zww, x0.yyz);
            i0.x = isX.x + isX.y + isX.z;
            i0.yzw = 1.0 - isX;
            i0.y += isYZ.x + isYZ.y;
            i0.zw += 1.0 - isYZ.xy;
            i0.z += isYZ.z;
            i0.w += 1.0 - isYZ.z;
            float4 i3 = clamp(i0, 0.0, 1.0);
            float4 i2 = clamp(i0-1.0, 0.0, 1.0);
            float4 i1 = clamp(i0-2.0, 0.0, 1.0);
            float4 x1 = x0 - i1 + C.xxxx;
            float4 x2 = x0 - i2 + C.yyyy;
            float4 x3 = x0 - i3 + C.zzzz;
            float4 x4 = x0 + C.wwww;
            i = fmod(i, 289.0);
            float j0 = fmod((i.w + float(dot(i, float4(1.0)))) * 289.0, 49.0);
            float4 j1 = fmod((float4(i.w + 1.0, i.w + i1.w, i.w + i2.w, i.w + i3.w) +
                              float4(dot(i.xyz + float3(0.0), float3(1.0)),
                                     dot(i.xyz + i1.xyz, float3(1.0)),
                                     dot(i.xyz + i2.xyz, float3(1.0)),
                                     dot(i.xyz + i3.xyz, float3(1.0)))) * 289.0, 49.0);
            float4 ip = float4(1.0/294.0, 1.0/49.0, 1.0/7.0, 0.0);
            float4 p0 = floor(j0 * ip.z) * ip.x + ip.yyyy;
            float4 p1 = floor(j1.x * ip.z) * ip.x + ip.yyyy;
            float4 p2 = floor(j1.y * ip.z) * ip.x + ip.yyyy;
            float4 p3 = floor(j1.z * ip.z) * ip.x + ip.yyyy;
            float4 p4 = floor(j1.w * ip.z) * ip.x + ip.yyyy;
            float4 norm = 1.79284291400159 - 0.85373472095314 *
                          float4(dot(p0,p0), dot(p1,p1), dot(p2,p2), dot(p3,p3));
            p0 *= norm.x; p1 *= norm.y; p2 *= norm.z; p3 *= norm.w;
            p4 *= 1.79284291400159 - 0.85373472095314 * dot(p4,p4);
            float3 m0 = max(0.6 - float3(dot(x0,x0), dot(x1,x1), dot(x2,x2)), 0.0);
            float2 m1 = max(0.6 - float2(dot(x3,x3), dot(x4,x4)), 0.0);
            m0 = m0 * m0;
            m1 = m1 * m1;
            return 49.0 * (dot(m0*m0, float3(dot(p0,x0), dot(p1,x1), dot(p2,x2))) +
                           dot(m1*m1, float2(dot(p3,x3), dot(p4,x4))));
        }

        """
    }

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
