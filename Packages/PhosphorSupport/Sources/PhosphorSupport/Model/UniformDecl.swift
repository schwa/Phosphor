import Foundation
import simd

/// A user-declared uniform exposed to the host UI as a control.
///
/// The runtime auto-generates a `struct UserUniforms { ... };` typedef from
/// the configuration's uniforms and prepends it to each pass's source before
/// compilation. The host UI renders a control per ``UniformUIHint``.
public struct UniformDecl: Hashable, Sendable {
    public var name: String
    public var kind: UniformKind
    public var defaultValue: UniformValue
    public var ui: UniformUIHint?

    public init(name: String, kind: UniformKind, defaultValue: UniformValue, ui: UniformUIHint? = nil) {
        self.name = name
        self.kind = kind
        self.defaultValue = defaultValue
        self.ui = ui
    }
}

/// Scalar/vector kind for a user uniform. Matches the host-side `UniformValue`.
public enum UniformKind: String, Hashable, Codable, Sendable, CaseIterable {
    case float
    case float2
    case float3
    case float4
    case int
    case bool
    case color
}

/// The actual value of a user uniform. Tagged union over the kinds.
public enum UniformValue: Hashable, Sendable {
    case float(Float)
    case float2(SIMD2<Float>)
    case float3(SIMD3<Float>)
    case float4(SIMD4<Float>)
    case int(Int32)
    case bool(Bool)

    public var kind: UniformKind {
        switch self {
        case .float: return .float
        case .float2: return .float2
        case .float3: return .float3
        case .float4: return .float4
        case .int: return .int
        case .bool: return .bool
        }
    }
}

/// UI control hint for a user uniform. Host renders controls accordingly.
public enum UniformUIHint: Hashable, Sendable {
    case slider(min: Float, max: Float)
    case color
    case toggle
    case vector
}
