import Foundation

/// The root document for a Phosphor 2 effect.
///
/// A dumb value type. Construction is unchecked; call ``validate(_:)`` to
/// surface structural errors at runtime.
public struct PhosphorEnvironment: Hashable, Codable, Sendable {
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
}

extension PhosphorEnvironment {
    /// Looks up a resource by ID in ``resources``. Returns nil if not present.
    public func resource(_ id: ResourceID) -> Resource? {
        resources.first { $0.id == id }
    }
}
