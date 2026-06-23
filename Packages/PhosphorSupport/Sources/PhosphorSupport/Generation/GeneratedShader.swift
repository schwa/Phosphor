import Foundation
import FoundationModels

/// Schema the Foundation Model produces when the user asks for a generated
/// shader. Flattened (no enums-with-payload) so `@Generable` can describe it
/// cleanly. ``toPhosphorConfiguration()`` converts to the runtime model.
///
/// The generation result has:
/// - One or more ``GeneratedPass``es (each one corresponds to a `kernel void`).
/// - One or more ``GeneratedResource``s (textures referenced by the passes).
/// - Zero or more ``GeneratedUniform``s (live UI controls).
/// - A single ``body`` string containing the actual MSL: helpers + one
///   `kernel void <pass.id>(...)` per declared pass.
@Generable
public struct GeneratedShader {
    @Guide(description: "Brief title for the effect, e.g. 'Plasma' or 'Game of Life'.")
    var title: String

    @Guide(description: "Required. Full MSL source: file-scope helpers plus one `kernel void <pass.id>(...)` per pass. Always non-empty; always contains at least one `kernel void` declaration. Output ONLY MSL source code; do NOT include any TOML front-matter or `#include` directives.")
    var body: String

    @Guide(description: "GPU resources (typically textures) read or written by the passes.")
    var resources: [GeneratedResource]

    @Guide(description: "Compute passes, in execution order. Each pass corresponds to one kernel function in the body.")
    var passes: [GeneratedPass]

    @Guide(description: "Optional live-editable uniforms. Empty if the effect doesn't need any.")
    var uniforms: [GeneratedUniform]

    @Guide(description: "Id of the resource that gets blitted to the screen. Must match one of resources[].id.")
    var outputResourceID: String

    @Guide(description: "Set true if the body uses GLSL/Shadertoy convention (Y=0 at the bottom). The runtime will flip the final blit vertically so the shader renders right-side up. Leave false for Phosphor-native code where Y=0 is at the top (which matches gid.y = 0).")
    var flipY: Bool
}

@Generable
public struct GeneratedResource {
    @Guide(description: "Resource identifier. Use lowercase letters, digits, and underscores only. Conventional names: 'image' for the final output buffer, 'bufA'/'bufB' for intermediates.")
    var id: String

    @Guide(description: "Pixel format. Use 'rgba32Float' for max precision (feedback effects), 'rgba16Float' for HDR with less bandwidth, 'rgba8Unorm' for simple low-precision output.")
    var format: GeneratedPixelFormat

    @Guide(description: "True if this resource is read AND written by the same pass (Shadertoy-style feedback). The runtime then keeps two textures and alternates each frame.")
    var pingPong: Bool

    @Guide(description: "Optional. To seed this texture with a built-in image, set the image name (one of: 'builtin:mandrill', 'builtin:testcard', 'builtin:noise-white', 'builtin:noise-white-rgb', 'builtin:noise-value', 'builtin:noise-fbm', 'builtin:noise-blue'). The texture is then sized to the image and pre-loaded with it. Leave EMPTY for a normal compute target. Do not invent other names.")
    var imageFile: String
}

@Generable
public enum GeneratedPixelFormat: String {
    case rgba8Unorm
    case rgba16Float
    case rgba32Float
}

@Generable
public struct GeneratedPass {
    @Guide(description: "Pass identifier. Also the name of the kernel function in the body. Conventional names: 'image' for the final pass, 'bufA' for intermediates.")
    var id: String

    @Guide(description: "Resource id this pass writes its output to. Must match one of resources[].id.")
    var output: String

    @Guide(description: "Channel inputs. Each binding picks one resource and exposes it as a texture inside `channels` (e.g. iChannel0 → bufA). Up to 4.")
    var inputs: [GeneratedBinding]
}

@Generable
public struct GeneratedBinding {
    @Guide(description: "Channel slot, one of: 'iChannel0', 'iChannel1', 'iChannel2', 'iChannel3'.")
    var name: String

    @Guide(description: "Resource id to bind to this channel. Must match one of resources[].id.")
    var resource: String
}

@Generable
public struct GeneratedUniform {
    @Guide(description: "Uniform identifier. Lowercase camelCase, e.g. 'intensity' or 'tintColor'.")
    var name: String

    @Guide(description: "Scalar kind. Use 'color' for an RGBA color picker, 'float' for a single number slider, 'bool' for a toggle.")
    var kind: GeneratedUniformKind

    @Guide(description: "Default value as 4 floats. For 'float'/'int'/'bool', only the first component is used (1 = true). For 'color'/'float4', all four. For 'float2'/'float3', the first 2/3.")
    var defaultValue: [Float]

    @Guide(description: "Slider minimum, if this uniform should be a slider. Ignored otherwise.")
    var sliderMin: Float

    @Guide(description: "Slider maximum. Ignored unless kind is float or int.")
    var sliderMax: Float
}

@Generable
public enum GeneratedUniformKind: String {
    case float
    case int
    case bool
    case color
}

// MARK: - Codable
//
// The generation schema types are made Codable so the exact decoded model
// response can be logged verbatim in the generation wire log (#99). The
// `@Generable` macro doesn't add Codable, so we conform explicitly; synthesis
// covers all members.

public extension GeneratedShader {
    /// Public read access to the model-chosen title (members are internal).
    var effectiveTitle: String { title }
}

extension GeneratedShader: Codable, Hashable, Sendable {}
extension GeneratedResource: Codable, Hashable, Sendable {}
extension GeneratedPixelFormat: Codable, Hashable, Sendable {}
extension GeneratedPass: Codable, Hashable, Sendable {}
extension GeneratedBinding: Codable, Hashable, Sendable {}
extension GeneratedUniform: Codable, Hashable, Sendable {}
extension GeneratedUniformKind: Codable, Hashable, Sendable {}

// MARK: - Conversion to runtime model

public extension GeneratedShader {
    /// Converts the schema to a runtime ``PhosphorConfiguration``.
    ///
    /// Validation is deliberately *not* run here: the generated source is
    /// validated once downstream, when it is parsed and compiled (issue #42).
    func toPhosphorConfiguration() -> PhosphorConfiguration {
        // Map the generator's resources -> textures with sensible defaults.
        // The generator schema still uses the old shape (single output
        // resource id per pass, separate channel inputs); we synthesize
        // bindings that include a write target for each pass's output.
        let textures: [Texture] = self.resources.map { resource in
            let trimmedFile = resource.imageFile.trimmingCharacters(in: .whitespacesAndNewlines)
            return Texture(
                id: ResourceID(resource.id),
                format: pixelFormat(from: resource.format),
                swap: resource.pingPong ? .endOfFrame : .none,
                initialContents: trimmedFile.isEmpty ? .zero : .image(file: trimmedFile)
            )
        }

        let passes: [Pass] = self.passes.map { pass in
            let outputID = ResourceID(pass.output)
            var bindings: [Pass.TextureBinding] = []
            bindings.append(.init(id: outputID, access: .write))
            for input in pass.inputs {
                let inputID = ResourceID(input.resource)
                // A read binding whose id matches the pass's write target is
                // self-feedback (ping-pong). The kernel-side `Textures` struct
                // names each field after its binding, so the read binding needs
                // a distinct name to avoid colliding with the write binding's
                // field. Name it `<id>Prev` (the "last" parity texture).
                if inputID == outputID {
                    bindings.append(.init(id: inputID, access: .read, name: "\(inputID.raw)Prev"))
                } else {
                    bindings.append(.init(id: inputID, access: .read))
                }
            }
            return Pass(id: ResourceID(pass.id), textures: bindings)
        }

        let uniforms: [UniformDecl] = self.uniforms.map { uniform in
            UniformDecl(
                name: uniform.name,
                kind: uniformKind(from: uniform.kind),
                defaultValue: uniformValue(uniform.defaultValue, kind: uniform.kind),
                ui: uniformUI(uniform)
            )
        }

        return PhosphorConfiguration(
            textures: textures,
            passes: passes,
            output: ResourceID(outputResourceID),
            uniforms: uniforms,
            flipY: flipY
        )
    }

    /// Renders a full `.metal` source string (prompt comments + front-matter +
    /// body) suitable to drop into a document.
    ///
    /// `prompts` is the full history of prompts that produced this shader,
    /// oldest first. Each is recorded as a separate `/* prompt: ... */` block
    /// at the top so the user can see how the shader evolved.
    func toMetalSource(prompts: [String] = []) throws -> String {
        let config = toPhosphorConfiguration()
        let toml = try FrontMatterFormatter.encodeBody(config)
        var output = ""
        for prompt in prompts where !prompt.isEmpty {
            output += "/* prompt: \(prompt) */\n"
        }
        if !prompts.isEmpty {
            output += "\n"
        }
        output += "\(FrontMatterFormatter.wrapFrontMatter(body: toml))\n\n\(body)\n"
        return output
    }

    private func pixelFormat(from generated: GeneratedPixelFormat) -> PhosphorPixelFormat {
        switch generated {
        case .rgba8Unorm: .rgba8Unorm
        case .rgba16Float: .rgba16Float
        case .rgba32Float: .rgba32Float
        }
    }

    private func uniformKind(from generated: GeneratedUniformKind) -> UniformKind {
        switch generated {
        case .float: .float
        case .int: .int
        case .bool: .bool
        case .color: .color
        }
    }

    private func uniformValue(_ values: [Float], kind: GeneratedUniformKind) -> UniformValue {
        let safe = values + Array(repeating: 0, count: max(0, 4 - values.count))
        switch kind {
        case .float: return .float(safe[0])
        case .int: return .int(Int32(safe[0]))
        case .bool: return .bool(safe[0] != 0)
        case .color: return .float4(.init(safe[0], safe[1], safe[2], safe[3]))
        }
    }

    private func uniformUI(_ uniform: GeneratedUniform) -> UniformUIHint? {
        switch uniform.kind {
        case .color: return .color
        case .bool: return .toggle

        case .float, .int:
            if uniform.sliderMin < uniform.sliderMax {
                return .slider(min: uniform.sliderMin, max: uniform.sliderMax)
            }
            return nil
        }
    }
}
