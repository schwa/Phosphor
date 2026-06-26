import CollaborationKit
import Foundation
import PhosphorModel

/// The JSON Schema for the `writeConfiguration` tool input, describing the
/// runtime ``PhosphorConfiguration`` shape *exactly* — the same shape
/// `readConfiguration` emits. There is one configuration representation: the
/// model reads and writes `PhosphorConfiguration` JSON directly.
///
/// Keys mirror the `Codable` shapes in PhosphorModel:
/// - `textures[]`: `{ id, size, format, swap, init }` (size/init are the
///   payload-enum shapes — `"drawable"` / `{fixed}` / `{scaledDrawable}`,
///   `{kind: "zero" | "fill" | "image" | "noise", ...}`).
/// - `passes[]`: `{ id, textures: [{ id, access, name? }], enabled? }`.
/// - `uniforms[]`: `{ name, kind, default, ui?, gesture? }`.
/// - `output`, `flipY`.
enum PhosphorConfigurationSchema {
    /// Builds a JSON Schema `enum` array from a `CaseIterable & RawRepresentable`
    /// model type, so the allowed values are *derived* from the model rather
    /// than hand-copied. Adding a case in PhosphorModel updates the schema
    /// automatically; the parity tests guard the few hand-curated lists that
    /// deliberately diverge (see below).
    static func enumValues<T: CaseIterable & RawRepresentable>(_: T.Type) -> JSONValue where T.RawValue == String {
        .array(T.allCases.map { .string($0.rawValue) })
    }

    static var jsonSchema: JSONValue {
        .object([
            "type": "object",
            "properties": .object([
                "configuration": configuration
            ]),
            "required": .array(["configuration"])
        ])
    }

    private static var configuration: JSONValue {
        .object([
            "type": "object",
            "description": "The complete shader configuration (the PhosphorConfiguration shape, identical to what readConfiguration returns).",
            "properties": .object([
                "output": .object([
                    "type": "string",
                    "description": "Id of the texture blitted to the screen. Must match a textures[].id."
                ]),
                "flipY": .object([
                    "type": "boolean",
                    "description": "True for GLSL/Shadertoy convention (Y=0 at bottom); the final blit is flipped. Omit/false for Phosphor-native (Y=0 at top)."
                ]),
                "textures": textures,
                "passes": passes,
                "uniforms": uniforms
            ]),
            // Only `output` is required: the decoder defaults textures/passes/
            // uniforms/flipY when absent (PhosphorConfiguration.init(from:)).
            // Advertising the others as required made the LLM-facing contract
            // stricter than the model actually accepts.
            "required": .array(["output"])
        ])
    }

    private static var textures: JSONValue {
        .object([
            "type": "array",
            "description": "Declared texture resources.",
            "items": .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "Texture id (lowercase letters, digits, underscores)."]),
                    "format": .object([
                        "type": "string",
                        "enum": enumValues(PhosphorPixelFormat.self),
                        "description": "Pixel format. Default 'rgba32Float'."
                    ]),
                    "swap": .object([
                        "type": "string",
                        // Hand-curated: SwapTiming also has `.immediate`, which is
                        // modeled but not implemented at runtime, so it is
                        // deliberately withheld from the model. Parity test
                        // asserts this stays a strict subset of SwapTiming.
                        "enum": .array(["none", "endOfFrame"]),
                        "description": "'endOfFrame' for ping-pong feedback (the runtime keeps two textures and alternates each frame); 'none' otherwise. Default 'none'."
                    ]),
                    "size": .object([
                        "description": "'drawable' (default) to match the view; or { fixed: { width, height } }; or { scaledDrawable: <float> }.",
                        "oneOf": .array([
                            .object(["type": "string", "enum": .array(["drawable"])]),
                            .object([
                                "type": "object",
                                "properties": .object([
                                    "fixed": .object([
                                        "type": "object",
                                        "properties": .object([
                                            "width": .object(["type": "integer"]),
                                            "height": .object(["type": "integer"])
                                        ]),
                                        "required": .array(["width", "height"])
                                    ])
                                ]),
                                "required": .array(["fixed"])
                            ]),
                            .object([
                                "type": "object",
                                "properties": .object(["scaledDrawable": .object(["type": "number"])]),
                                "required": .array(["scaledDrawable"])
                            ])
                        ])
                    ]),
                    "init": .object([
                        "type": "object",
                        "description": "Initial contents. { kind: 'zero' } (default); { kind: 'fill', color: [r,g,b,a] }; { kind: 'image', file: '<built-in name>' } e.g. 'builtin:mandrill'; { kind: 'noise', seed: <int> }.",
                        "properties": .object([
                            "kind": .object([
                                "type": "string",
                                "enum": .array(["zero", "fill", "image", "noise"])
                            ]),
                            "color": .object([
                                "type": "array",
                                "items": .object(["type": "number"]),
                                "description": "RGBA for kind 'fill'."
                            ]),
                            "file": .object(["type": "string", "description": "Built-in image name for kind 'image'."]),
                            "seed": .object(["type": "integer", "description": "Seed for kind 'noise'."])
                        ]),
                        "required": .array(["kind"])
                    ])
                ]),
                "required": .array(["id"])
            ])
        ])
    }

    private static var passes: JSONValue {
        .object([
            "type": "array",
            "description": "Compute passes in execution order. Each corresponds to one kernel function named after its id.",
            "items": .object([
                "type": "object",
                "properties": .object([
                    "id": .object(["type": "string", "description": "Pass id; also the kernel function name."]),
                    "enabled": .object(["type": "boolean", "description": "Default true."]),
                    "textures": .object([
                        "type": "array",
                        "description": "Per-pass texture bindings. Include one 'write' binding for the pass's output texture, plus a 'read' (or 'sample') binding for each input. For feedback (ping-pong) the pass reads the previous frame via a second binding on the same texture id with a distinct 'name' (conventionally '<id>Prev').",
                        "items": .object([
                            "type": "object",
                            "properties": .object([
                                "id": .object(["type": "string", "description": "Texture id this binding refers to (must match a textures[].id)."]),
                                "access": .object([
                                    "type": "string",
                                    // Hand-curated to match TextureAccess (not
                                    // CaseIterable on the published model). Parity
                                    // test asserts these are all valid cases.
                                    "enum": .array(["read", "sample", "write", "readWrite"]),
                                    "description": "MSL access: 'write' for the output; 'read' for integer-coord input; 'sample' for filtered input."
                                ]),
                                "name": .object([
                                    "type": "string",
                                    "description": "Optional binding-name override (defaults to id). Needed when binding the same texture twice, e.g. a 'write' to <id> and a 'read' to '<id>Prev' for feedback."
                                ])
                            ]),
                            "required": .array(["id", "access"])
                        ])
                    ])
                ]),
                "required": .array(["id", "textures"])
            ])
        ])
    }

    private static var uniforms: JSONValue {
        .object([
            "type": "array",
            "description": "Optional live-editable uniforms.",
            "items": .object([
                "type": "object",
                "properties": .object([
                    "name": .object(["type": "string", "description": "Uniform id (lowerCamelCase)."]),
                    "kind": .object([
                        "type": "string",
                        "enum": enumValues(UniformKind.self),
                        "description": "Scalar/vector kind."
                    ]),
                    "default": .object([
                        "description": "Default value: a number for float/int, a bool for bool, or an array of floats for float2/3/4/color.",
                        "oneOf": .array([
                            .object(["type": "number"]),
                            .object(["type": "boolean"]),
                            .object(["type": "array", "items": .object(["type": "number"])])
                        ])
                    ]),
                    "ui": .object([
                        "description": "UI hint: { slider: { min, max } } for a float/int slider; 'color'; 'toggle'; 'vector'.",
                        "oneOf": .array([
                            .object(["type": "string", "enum": .array(["color", "toggle", "vector"])]),
                            .object([
                                "type": "object",
                                "properties": .object([
                                    "slider": .object([
                                        "type": "object",
                                        "properties": .object([
                                            "min": .object(["type": "number"]),
                                            "max": .object(["type": "number"])
                                        ]),
                                        "required": .array(["min", "max"])
                                    ])
                                ]),
                                "required": .array(["slider"])
                            ])
                        ])
                    ]),
                    "gesture": .object([
                        "type": "string",
                        "enum": enumValues(UniformGesture.self),
                        "description": "Optional. Bind a render-surface gesture to drive this uniform live (float only; each gesture used by at most one uniform). 'x'/'y' map a drag to the slider range; 'zoom' a pinch; 'rotate' a rotation."
                    ])
                ]),
                "required": .array(["name", "kind", "default"])
            ])
        ])
    }
}
