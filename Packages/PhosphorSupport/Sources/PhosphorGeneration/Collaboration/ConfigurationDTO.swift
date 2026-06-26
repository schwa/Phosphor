import CollaborationKit
import Foundation
import PhosphorModel
import simd

/// A flat, model-friendly mirror of ``PhosphorConfiguration`` for the
/// `writeConfiguration` tool.
///
/// The runtime configuration uses payload-carrying enums (`TextureSize`,
/// `TextureInit`, `UniformValue`) whose Codable shapes are tuned for
/// hand-written TOML, not for a model to emit. ``ConfigurationDTO`` deliberately
/// reuses the same *flattened* shape the `@Generable` ``GeneratedShader`` schema
/// already proves works for models (id/format/pingPong/imageFile resources,
/// id/output/inputs passes, scalar uniforms) and maps it to the runtime model
/// with the same binding-synthesis rules as
/// ``GeneratedShader/toPhosphorConfiguration()``.
///
/// The hand-written ``jsonSchema`` is the contract presented to the model.
public struct ConfigurationDTO: Decodable, Sendable {
    public var resources: [ResourceDTO]
    public var passes: [PassDTO]
    public var uniforms: [UniformDTO]
    public var output: String
    public var flipY: Bool

    private enum CodingKeys: String, CodingKey {
        case resources, passes, uniforms, output, flipY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resources = try container.decodeIfPresent([ResourceDTO].self, forKey: .resources) ?? []
        self.passes = try container.decodeIfPresent([PassDTO].self, forKey: .passes) ?? []
        self.uniforms = try container.decodeIfPresent([UniformDTO].self, forKey: .uniforms) ?? []
        self.output = try container.decode(String.self, forKey: .output)
        self.flipY = try container.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
    }

    public struct ResourceDTO: Decodable, Sendable {
        public var id: String
        public var format: String
        public var pingPong: Bool
        public var imageFile: String

        private enum CodingKeys: String, CodingKey { case id, format, pingPong, imageFile }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.format = try c.decodeIfPresent(String.self, forKey: .format) ?? "rgba32Float"
            self.pingPong = try c.decodeIfPresent(Bool.self, forKey: .pingPong) ?? false
            self.imageFile = try c.decodeIfPresent(String.self, forKey: .imageFile) ?? ""
        }
    }

    public struct PassDTO: Decodable, Sendable {
        public var id: String
        public var output: String
        public var inputs: [BindingDTO]

        private enum CodingKeys: String, CodingKey { case id, output, inputs }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(String.self, forKey: .id)
            self.output = try c.decode(String.self, forKey: .output)
            self.inputs = try c.decodeIfPresent([BindingDTO].self, forKey: .inputs) ?? []
        }
    }

    public struct BindingDTO: Decodable, Sendable {
        public var name: String
        public var resource: String
    }

    public struct UniformDTO: Decodable, Sendable {
        public var name: String
        public var kind: String
        public var defaultValue: [Float]
        public var sliderMin: Float
        public var sliderMax: Float
        /// Optional gesture channel ("x", "y", "zoom", "rotate"), or empty/"none".
        public var gesture: String

        private enum CodingKeys: String, CodingKey { case name, kind, defaultValue, sliderMin, sliderMax, gesture }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.name = try c.decode(String.self, forKey: .name)
            self.kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "float"
            self.defaultValue = try c.decodeIfPresent([Float].self, forKey: .defaultValue) ?? []
            self.sliderMin = try c.decodeIfPresent(Float.self, forKey: .sliderMin) ?? 0
            self.sliderMax = try c.decodeIfPresent(Float.self, forKey: .sliderMax) ?? 0
            self.gesture = try c.decodeIfPresent(String.self, forKey: .gesture) ?? ""
        }
    }

    // MARK: - Mapping to the runtime model

    /// Maps the flat DTO to a runtime ``PhosphorConfiguration``, synthesizing
    /// the per-binding access list exactly as
    /// ``GeneratedShader/toPhosphorConfiguration()`` does.
    public func toConfiguration() -> PhosphorConfiguration {
        let textures: [Texture] = resources.map { resource in
            let trimmed = resource.imageFile.trimmingCharacters(in: .whitespacesAndNewlines)
            return Texture(
                id: ResourceID(resource.id),
                format: Self.pixelFormat(resource.format),
                swap: resource.pingPong ? .endOfFrame : .none,
                initialContents: trimmed.isEmpty ? .zero : .image(file: trimmed)
            )
        }

        let passes: [Pass] = passes.map { pass in
            let outputID = ResourceID(pass.output)
            var bindings: [Pass.TextureBinding] = [.init(id: outputID, access: .write)]
            for input in pass.inputs {
                let inputID = ResourceID(input.resource)
                if inputID == outputID {
                    bindings.append(.init(id: inputID, access: .read, name: "\(inputID.raw)Prev"))
                } else {
                    bindings.append(.init(id: inputID, access: .read))
                }
            }
            return Pass(id: ResourceID(pass.id), textures: bindings)
        }

        let uniforms: [UniformDecl] = uniforms.map { uniform in
            let kind = Self.uniformKind(uniform.kind)
            return UniformDecl(
                name: uniform.name,
                kind: kind,
                defaultValue: Self.uniformValue(uniform.defaultValue, kind: kind),
                ui: Self.uniformUI(uniform, kind: kind),
                gesture: Self.uniformGesture(uniform.gesture, kind: kind)
            )
        }

        return PhosphorConfiguration(
            textures: textures,
            passes: passes,
            output: ResourceID(output),
            uniforms: uniforms,
            flipY: flipY
        )
    }

    private static func pixelFormat(_ raw: String) -> PhosphorPixelFormat {
        PhosphorPixelFormat(rawValue: raw) ?? .rgba32Float
    }

    private static func uniformKind(_ raw: String) -> UniformKind {
        UniformKind(rawValue: raw) ?? .float
    }

    private static func uniformValue(_ values: [Float], kind: UniformKind) -> UniformValue {
        let safe = values + Array(repeating: 0, count: max(0, 4 - values.count))
        switch kind {
        case .float: return .float(safe[0])
        case .float2: return .float2(.init(safe[0], safe[1]))
        case .float3: return .float3(.init(safe[0], safe[1], safe[2]))
        case .float4, .color: return .float4(.init(safe[0], safe[1], safe[2], safe[3]))

        case .int: return .int(Int32(safe[0]))
        case .bool: return .bool(safe[0] != 0)
        }
    }

    /// Maps the raw gesture string to a ``UniformGesture``. Only valid on
    /// `.float`; anything else (or empty/"none"/unknown) yields `nil`.
    private static func uniformGesture(_ raw: String, kind: UniformKind) -> UniformGesture? {
        guard kind == .float else { return nil }
        return UniformGesture(rawValue: raw)
    }

    private static func uniformUI(_ uniform: UniformDTO, kind: UniformKind) -> UniformUIHint? {
        switch kind {
        case .color: return .color

        case .bool: return .toggle

        case .float2, .float3, .float4: return .vector

        case .float, .int:
            if uniform.sliderMin < uniform.sliderMax {
                return .slider(min: uniform.sliderMin, max: uniform.sliderMax)
            }
            return nil
        }
    }

    // MARK: - JSON Schema

    /// The JSON Schema for the `writeConfiguration` tool input. Mirrors the
    /// flat DTO shape above and the `@Generable` ``GeneratedShader`` schema.
    public static var jsonSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "configuration": .object([
                    "type": "object",
                    "description": "The complete shader configuration.",
                    "properties": .object([
                        "output": .object([
                            "type": "string",
                            "description": "Id of the resource blitted to the screen. Must match a resources[].id."
                        ]),
                        "flipY": .object([
                            "type": "boolean",
                            "description": "True for GLSL/Shadertoy convention (Y=0 at bottom); the final blit is flipped."
                        ]),
                        "resources": .object([
                            "type": "array",
                            "description": "GPU resources (textures) read or written by the passes.",
                            "items": .object([
                                "type": "object",
                                "properties": .object([
                                    "id": .object(["type": "string", "description": "Resource id (lowercase letters, digits, underscores)."]),
                                    "format": .object([
                                        "type": "string",
                                        "enum": .array(["rgba8Unorm", "bgra8Unorm", "rgba16Float", "rgba32Float"]),
                                        "description": "Pixel format."
                                    ]),
                                    "pingPong": .object(["type": "boolean", "description": "True if read AND written by the same pass (feedback)."]),
                                    "imageFile": .object(["type": "string", "description": "Optional built-in image name to seed with (e.g. 'builtin:mandrill'), else empty."])
                                ]),
                                "required": .array(["id"])
                            ])
                        ]),
                        "passes": .object([
                            "type": "array",
                            "description": "Compute passes in execution order. Each corresponds to one kernel function.",
                            "items": .object([
                                "type": "object",
                                "properties": .object([
                                    "id": .object(["type": "string", "description": "Pass id; also the kernel function name."]),
                                    "output": .object(["type": "string", "description": "Resource id this pass writes to."]),
                                    "inputs": .object([
                                        "type": "array",
                                        "description": "Channel inputs (up to 4).",
                                        "items": .object([
                                            "type": "object",
                                            "properties": .object([
                                                "name": .object(["type": "string", "description": "Channel slot, e.g. 'iChannel0'."]),
                                                "resource": .object(["type": "string", "description": "Resource id to bind."])
                                            ]),
                                            "required": .array(["name", "resource"])
                                        ])
                                    ])
                                ]),
                                "required": .array(["id", "output"])
                            ])
                        ]),
                        "uniforms": .object([
                            "type": "array",
                            "description": "Optional live-editable uniforms.",
                            "items": .object([
                                "type": "object",
                                "properties": .object([
                                    "name": .object(["type": "string", "description": "Uniform id (lowerCamelCase)."]),
                                    "kind": .object([
                                        "type": "string",
                                        "enum": .array(["float", "float2", "float3", "float4", "int", "bool", "color"]),
                                        "description": "Scalar/vector kind."
                                    ]),
                                    "defaultValue": .object([
                                        "type": "array",
                                        "items": .object(["type": "number"]),
                                        "description": "Default as up to 4 floats."
                                    ]),
                                    "sliderMin": .object(["type": "number", "description": "Slider minimum (float/int only)."]),
                                    "sliderMax": .object(["type": "number", "description": "Slider maximum (float/int only)."]),
                                    "gesture": .object([
                                        "type": "string",
                                        "enum": .array(["none", "x", "y", "zoom", "rotate"]),
                                        "description": "Optional render-surface gesture that drives this uniform live (float only; each gesture used by at most one uniform). 'x'/'y' map a drag to 0..1 over the slider range; 'zoom' a pinch; 'rotate' a rotation. Use 'none' unless direct manipulation clearly helps."
                                    ])
                                ]),
                                "required": .array(["name", "kind"])
                            ])
                        ])
                    ]),
                    "required": .array(["output"])
                ])
            ]),
            "required": .array(["configuration"])
        ])
    }
}
