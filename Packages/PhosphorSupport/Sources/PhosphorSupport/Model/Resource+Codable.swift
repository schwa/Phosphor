import Foundation

// Custom Codable for the model types so the TOML front-matter shape matches
// what authors actually want to write.
//
// Conventions:
// - Unit enum cases (no payload) encode as a bare string.
// - Discriminated enums use `kind = "..."` plus the case's fields side by side.
// - Everything else uses the default keyed-container Codable.

// MARK: - Texture

extension Texture: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case size
        case format
        case swap
        case initialContents = "init"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(size, forKey: .size)
        try container.encode(format, forKey: .format)
        try container.encode(swap, forKey: .swap)
        try container.encode(initialContents, forKey: .initialContents)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ResourceID.self, forKey: .id)
        self.size = try container.decodeIfPresent(TextureSize.self, forKey: .size) ?? .drawable
        self.format = try container.decodeIfPresent(PhosphorPixelFormat.self, forKey: .format) ?? .rgba32Float
        self.swap = try container.decodeIfPresent(SwapTiming.self, forKey: .swap) ?? .none
        self.initialContents = try container.decodeIfPresent(TextureInit.self, forKey: .initialContents) ?? .zero
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
    private enum CodingKeys: String, CodingKey {
        case kind
        case color
        case file
        case seed
    }

    private enum Kind: String, Codable {
        case zero
        case fill
        case image
        case noise
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .zero:
            try container.encode(Kind.zero, forKey: .kind)

        case .fill(let rgba):
            try container.encode(Kind.fill, forKey: .kind)
            try container.encode([rgba.x, rgba.y, rgba.z, rgba.w], forKey: .color)

        case .image(let file):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(file, forKey: .file)

        case .noise(let seed):
            try container.encode(Kind.noise, forKey: .kind)
            try container.encode(seed, forKey: .seed)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .zero:
            self = .zero

        case .fill:
            let rgba = try container.decode([Float].self, forKey: .color)
            guard rgba.count == 4 else {
                throw DecodingError.dataCorruptedError(forKey: .color, in: container, debugDescription: "fill color must have 4 components")
            }
            self = .fill(.init(rgba[0], rgba[1], rgba[2], rgba[3]))

        case .image:
            let file = try container.decode(String.self, forKey: .file)
            self = .image(file: file)

        case .noise:
            let seed = try container.decode(UInt64.self, forKey: .seed)
            self = .noise(seed: seed)
        }
    }
}
