import Foundation
import simd

// Custom Codable for UniformDecl / UniformValue / UniformUIHint so the TOML
// front-matter shape is hand-friendly.
//
// Encoding:
//   [[uniforms]]
//   name = "intensity"
//   kind = "float"
//   default = 1.0
//   ui = { slider = { min = 0.0, max = 4.0 } }

// MARK: - UniformDecl

extension UniformDecl: Codable {
    private enum CodingKeys: String, CodingKey {
        case name
        case kind
        case `default`
        case ui
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encode(defaultValue, forKey: .default)
        try container.encodeIfPresent(ui, forKey: .ui)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let kind = try container.decode(UniformKind.self, forKey: .kind)
        let ui = try container.decodeIfPresent(UniformUIHint.self, forKey: .ui)
        let defaultValue = try Self.decodeValue(kind: kind, container: container, key: .default)
        self.init(name: name, kind: kind, defaultValue: defaultValue, ui: ui)
    }

    /// Decodes `default` based on the declared kind. Plain Codable wouldn't
    /// know which case of `UniformValue` to pick from a bare TOML scalar.
    private static func decodeValue(kind: UniformKind, container: KeyedDecodingContainer<CodingKeys>, key: CodingKeys) throws -> UniformValue {
        switch kind {
        case .float:
            return .float(try container.decode(Float.self, forKey: key))

        case .float2:
            let values = try container.decode([Float].self, forKey: key)
            guard values.count == 2 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "float2 requires 2 components, got \(values.count)")
            }
            return .float2(.init(values[0], values[1]))

        case .float3:
            let values = try container.decode([Float].self, forKey: key)
            guard values.count == 3 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "float3 requires 3 components, got \(values.count)")
            }
            return .float3(.init(values[0], values[1], values[2]))

        case .float4, .color:
            let values = try container.decode([Float].self, forKey: key)
            guard values.count == 4 else {
                throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "\(kind.rawValue) requires 4 components, got \(values.count)")
            }
            return .float4(.init(values[0], values[1], values[2], values[3]))

        case .int:
            return .int(try container.decode(Int32.self, forKey: key))

        case .bool:
            return .bool(try container.decode(Bool.self, forKey: key))
        }
    }
}

// MARK: - UniformValue (kept simple — only used for codable round-trip outside UniformDecl)

extension UniformValue: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .float(let value):
            try container.encode(value)

        case .float2(let value):
            try container.encode([value.x, value.y])

        case .float3(let value):
            try container.encode([value.x, value.y, value.z])

        case .float4(let value):
            try container.encode([value.x, value.y, value.z, value.w])

        case .int(let value):
            try container.encode(value)

        case .bool(let value):
            try container.encode(value)
        }
    }

    /// The default `init(from:)` here can't know which kind to pick from a
    /// bare scalar, so it requires a UniformValueDecoderHint in userInfo if
    /// you decode it standalone. Inside `UniformDecl`, this is bypassed
    /// because `UniformDecl.init(from:)` calls `decodeValue(kind:)` directly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let bool = try? container.decode(Bool.self) {
            self = .bool(bool)
        } else if let int = try? container.decode(Int32.self) {
            self = .int(int)
        } else if let float = try? container.decode(Float.self) {
            self = .float(float)
        } else if let array = try? container.decode([Float].self) {
            switch array.count {
            case 2: self = .float2(.init(array[0], array[1]))
            case 3: self = .float3(.init(array[0], array[1], array[2]))
            case 4: self = .float4(.init(array[0], array[1], array[2], array[3]))
            default: throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported float vector count \(array.count)")
            }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown UniformValue shape")
        }
    }
}

// MARK: - UniformUIHint

extension UniformUIHint: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .color:
            try container.encode("color")

        case .toggle:
            try container.encode("toggle")

        case .vector:
            try container.encode("vector")

        case .slider(let minValue, let maxValue):
            try container.encode(Wrapped(slider: SliderPayload(min: minValue, max: maxValue)))
        }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            switch string {
            case "color": self = .color; return
            case "toggle": self = .toggle; return
            case "vector": self = .vector; return

            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown UniformUIHint string '\(string)'")
            }
        }
        let container = try decoder.container(keyedBy: KeyedKey.self)
        if let slider = try? container.decode(SliderPayload.self, forKey: .slider) {
            self = .slider(min: slider.min, max: slider.max)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown UniformUIHint shape"))
        }
    }

    private enum KeyedKey: String, CodingKey {
        case slider
    }

    private struct SliderPayload: Codable {
        var min: Float
        var max: Float
    }

    private struct Wrapped: Encodable {
        var slider: SliderPayload?
        init(slider: SliderPayload) { self.slider = slider }
    }
}
