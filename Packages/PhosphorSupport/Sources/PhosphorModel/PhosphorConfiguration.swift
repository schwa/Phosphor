import Foundation

/// The root document for a Phosphor 2 effect.
///
/// A dumb value type. Construction is unchecked; call ``validate(_:)`` to
/// surface structural errors at runtime.
public struct PhosphorConfiguration: Hashable, Sendable, Codable {
    public var textures: [Texture]
    public var passes: [Pass]
    /// Id of the texture that gets blitted to the drawable for preview.
    /// Distinct from any per-pass write targets — those are derived from
    /// each pass's binding list.
    public var output: ResourceID
    public var uniforms: [UniformDecl]
    /// If `true`, the final blit to the drawable flips vertically — useful for
    /// Shadertoy / GLSL-convention shaders that assume Y=0 is at the bottom.
    /// Default is `false` (Phosphor convention: gid.y=0 is at the top).
    public var flipY: Bool

    public init(
        textures: [Texture] = [],
        passes: [Pass] = [],
        output: ResourceID,
        uniforms: [UniformDecl] = [],
        flipY: Bool = false
    ) {
        self.textures = textures
        self.passes = passes
        self.output = output
        self.uniforms = uniforms
        self.flipY = flipY
    }

    private enum CodingKeys: String, CodingKey {
        case textures
        case passes
        case output
        case uniforms
        case flipY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.textures = try container.decodeIfPresent([Texture].self, forKey: .textures) ?? []
        self.passes = try container.decodeIfPresent([Pass].self, forKey: .passes) ?? []
        self.output = try container.decode(ResourceID.self, forKey: .output)
        self.uniforms = try container.decodeIfPresent([UniformDecl].self, forKey: .uniforms) ?? []
        self.flipY = try container.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(textures, forKey: .textures)
        try container.encode(passes, forKey: .passes)
        try container.encode(output, forKey: .output)
        try container.encode(uniforms, forKey: .uniforms)
        if flipY {
            try container.encode(flipY, forKey: .flipY)
        }
    }
}

extension PhosphorConfiguration {
    /// Looks up a texture by id. Returns nil if not present.
    public func texture(_ id: ResourceID) -> Texture? {
        textures.first { $0.id == id }
    }
}
