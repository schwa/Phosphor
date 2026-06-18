import Foundation

/// One compute pass. Its `id` is also the name of the Metal `kernel void`
/// function that the runtime looks up after compilation.
public struct Pass: Hashable, Sendable, Codable {
    public var id: ResourceID
    public var inputs: [Input]
    public var output: ResourceID
    public var enabled: Bool

    public init(
        id: ResourceID,
        inputs: [Input] = [],
        output: ResourceID,
        enabled: Bool = true
    ) {
        self.id = id
        self.inputs = inputs
        self.output = output
        self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case inputs
        case output
        case enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(ResourceID.self, forKey: .id)
        self.inputs = try container.decodeIfPresent([Input].self, forKey: .inputs) ?? []
        self.output = try container.decode(ResourceID.self, forKey: .output)
        self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(inputs, forKey: .inputs)
        try container.encode(output, forKey: .output)
        try container.encode(enabled, forKey: .enabled)
    }

    /// Binds one of the auto-generated ``ChannelBindings`` slots to a resource.
    ///
    /// `name` must be of the form `"iChannelN"`; the inferred channel count is
    /// derived from the highest `N` referenced across all passes.
    ///
    /// Nested in ``Pass`` to keep the name out of the top-level namespace,
    /// where it collides with SwiftUI's `Binding`.
    public struct Input: Hashable, Codable, Sendable {
        public var name: String
        public var resource: ResourceID

        public init(name: String, resource: ResourceID) {
            self.name = name
            self.resource = resource
        }
    }
}
