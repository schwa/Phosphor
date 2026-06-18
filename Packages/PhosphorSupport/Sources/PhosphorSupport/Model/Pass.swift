import Foundation

/// One compute pass. Its `id` is also the name of the Metal `kernel void`
/// function that the runtime looks up after compilation.
public struct Pass: Hashable, Codable, Sendable {
    public var id: ResourceID
    public var inputs: [Binding]
    public var output: ResourceID
    public var enabled: Bool

    public init(
        id: ResourceID,
        inputs: [Binding] = [],
        output: ResourceID,
        enabled: Bool = true
    ) {
        self.id = id
        self.inputs = inputs
        self.output = output
        self.enabled = enabled
    }
}

/// Binds one of the auto-generated ``ChannelBindings`` slots to a resource.
///
/// `name` must be of the form `"iChannelN"`; the inferred channel count is
/// derived from the highest `N` referenced across all passes.
public struct Binding: Hashable, Codable, Sendable {
    public var name: String
    public var resource: ResourceID

    public init(name: String, resource: ResourceID) {
        self.name = name
        self.resource = resource
    }
}
