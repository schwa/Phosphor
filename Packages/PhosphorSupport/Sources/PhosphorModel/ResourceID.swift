import Foundation

/// Identifies a resource (texture, pass, etc.) inside a ``PhosphorConfiguration``.
///
/// Just a string under the hood. Conforms to `ExpressibleByStringLiteral` so
/// builder code can write `"bufA"` and have it become a `ResourceID`.
public struct ResourceID: Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public init(stringLiteral value: String) {
        self.raw = value
    }

    public var description: String { raw }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.raw = try container.decode(String.self)
    }
}
