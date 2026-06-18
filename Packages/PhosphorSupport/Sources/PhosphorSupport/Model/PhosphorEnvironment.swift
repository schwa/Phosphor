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

    public init(
        resources: [Resource] = [],
        passes: [Pass] = [],
        output: ResourceID,
        uniforms: [UniformDecl] = []
    ) {
        self.resources = resources
        self.passes = passes
        self.output = output
        self.uniforms = uniforms
    }

    private enum CodingKeys: String, CodingKey {
        case resources
        case passes
        case output
        case uniforms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.resources = try container.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        self.passes = try container.decodeIfPresent([Pass].self, forKey: .passes) ?? []
        self.output = try container.decode(ResourceID.self, forKey: .output)
        self.uniforms = try container.decodeIfPresent([UniformDecl].self, forKey: .uniforms) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(resources, forKey: .resources)
        try container.encode(passes, forKey: .passes)
        try container.encode(output, forKey: .output)
        try container.encode(uniforms, forKey: .uniforms)
    }
}

extension PhosphorEnvironment {
    /// Looks up a resource by ID in ``resources``. Returns nil if not present.
    public func resource(_ id: ResourceID) -> Resource? {
        resources.first { $0.id == id }
    }
}
