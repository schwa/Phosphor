import Foundation

// Custom Codable for the model enums so the TOML front-matter shape matches
// what authors actually want to write.
//
// Conventions:
// - Unit enum cases (no payload) encode as a bare string.
// - Cases with one labeled payload encode as a nested table under the case name.
// - The `Resource` enum is flattened: `kind = "texture2D"`, `id = ...`, `spec = {...}`.

// MARK: - Resource

extension Resource: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case spec
    }

    private enum Kind: String, Codable {
        case texture2D
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .texture2D(let id, let spec):
            try container.encode(Kind.texture2D, forKey: .kind)
            try container.encode(id, forKey: .id)
            try container.encode(spec, forKey: .spec)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .texture2D:
            let id = try container.decode(ResourceID.self, forKey: .id)
            let spec = try container.decode(Texture2DSpec.self, forKey: .spec)
            self = .texture2D(id: id, spec: spec)
        }
    }
}

// MARK: - TextureSize

extension TextureSize: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .drawable:
            try container.encode("drawable")
        case .fixed(let width, let height):
            try container.encode(Sized(fixed: .init(width: width, height: height)))
        case .scaledDrawable(let scale):
            try container.encode(Scaled(scaledDrawable: scale))
        }
    }

    public init(from decoder: Decoder) throws {
        // Try string first.
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            switch string {
            case "drawable":
                self = .drawable
                return
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown TextureSize string '\(string)'")
            }
        }
        // Fall back to keyed shapes.
        let container = try decoder.container(keyedBy: KeyedKey.self)
        if let fixed = try? container.decode(FixedSize.self, forKey: .fixed) {
            self = .fixed(width: fixed.width, height: fixed.height)
        } else if let scale = try? container.decode(Float.self, forKey: .scaledDrawable) {
            self = .scaledDrawable(scale)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown TextureSize shape"))
        }
    }

    private enum KeyedKey: String, CodingKey {
        case fixed
        case scaledDrawable
    }

    private struct FixedSize: Codable {
        var width: Int
        var height: Int
    }

    private struct Sized: Encodable {
        var fixed: FixedSize
    }

    private struct Scaled: Encodable {
        var scaledDrawable: Float
    }
}

// MARK: - TextureInit

extension TextureInit: Codable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .zero:
            try container.encode("zero")
        case .color(let rgba):
            try container.encode(Wrapped(color: [rgba.x, rgba.y, rgba.z, rgba.w]))
        case .image(let name):
            try container.encode(Wrapped(image: ImagePayload(name: name)))
        case .noise(let seed):
            try container.encode(Wrapped(noise: NoisePayload(seed: seed)))
        }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let string = try? container.decode(String.self) {
            switch string {
            case "zero":
                self = .zero
                return
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown TextureInit string '\(string)'")
            }
        }
        let container = try decoder.container(keyedBy: KeyedKey.self)
        if let rgba = try? container.decode([Float].self, forKey: .color), rgba.count == 4 {
            self = .color(.init(rgba[0], rgba[1], rgba[2], rgba[3]))
        } else if let image = try? container.decode(ImagePayload.self, forKey: .image) {
            self = .image(name: image.name)
        } else if let noise = try? container.decode(NoisePayload.self, forKey: .noise) {
            self = .noise(seed: noise.seed)
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown TextureInit shape"))
        }
    }

    private enum KeyedKey: String, CodingKey {
        case color
        case image
        case noise
    }

    private struct ImagePayload: Codable {
        var name: String
    }

    private struct NoisePayload: Codable {
        var seed: UInt64
    }

    private struct Wrapped: Encodable {
        var color: [Float]?
        var image: ImagePayload?
        var noise: NoisePayload?

        init(color: [Float]) { self.color = color }
        init(image: ImagePayload) { self.image = image }
        init(noise: NoisePayload) { self.noise = noise }
    }
}
