import Foundation

/// The root document for a Phosphor 2 effect.
///
/// A dumb value type. Construction is unchecked; call ``validate(_:)`` to
/// surface structural errors at runtime.
public struct PhosphorEnvironment: Hashable, Sendable, Codable {
    public var resources: [Resource]
    public var passes: [Pass]
    public var output: ResourceID
    public var uniforms: [UniformDecl]
    /// If `true`, the final blit to the drawable flips vertically — useful for
    /// Shadertoy / GLSL-convention shaders that assume Y=0 is at the bottom.
    /// Default is `false` (Phosphor convention: gid.y=0 is at the top).
    public var flipY: Bool

    public init(
        resources: [Resource] = [],
        passes: [Pass] = [],
        output: ResourceID,
        uniforms: [UniformDecl] = [],
        flipY: Bool = false
    ) {
        self.resources = resources
        self.passes = passes
        self.output = output
        self.uniforms = uniforms
        self.flipY = flipY
    }

    private enum CodingKeys: String, CodingKey {
        case resources
        case passes
        case output
        case uniforms
        case flipY
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        self.passes = try container.decodeIfPresent([Pass].self, forKey: .passes) ?? []
        self.output = try container.decode(ResourceID.self, forKey: .output)
        self.uniforms = try container.decodeIfPresent([UniformDecl].self, forKey: .uniforms) ?? []
        self.flipY = try container.decodeIfPresent(Bool.self, forKey: .flipY) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resources, forKey: .resources)
        try container.encode(passes, forKey: .passes)
        try container.encode(output, forKey: .output)
        try container.encode(uniforms, forKey: .uniforms)
        if flipY {
            try container.encode(flipY, forKey: .flipY)
        }
    }
}

extension PhosphorEnvironment {
    /// Looks up a resource by ID in ``resources``. Returns nil if not present.
    public func resource(_ id: ResourceID) -> Resource? {
        resources.first { $0.id == id }
    }
}
