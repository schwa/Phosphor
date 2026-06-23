import Foundation
import PhosphorModel
import simd

/// Computes the byte layout of the auto-generated MSL `UserUniforms` struct
/// from an ordered `[UniformDecl]`, and packs `UniformValue`s into a buffer
/// using that layout.
///
/// The layout MUST match the MSL struct emitted by ``PhosphorHeader/userUniformsDecl(uniforms:)``.
/// MSL alignment rules:
///
/// | type     | align | size |
/// | -------- | ----- | ---- |
/// | float    |     4 |    4 |
/// | int/uint |     4 |    4 |
/// | bool     |     1 |    1 |
/// | float2   |     8 |    8 |
/// | float3   |    16 |   16 |  (12 bytes data + 4 bytes padding)
/// | float4   |    16 |   16 |
///
/// Struct size is rounded up to its strictest member alignment.
public enum UserUniformsLayout {
    public struct FieldLayout: Hashable, Sendable {
        public var name: String
        public var kind: UniformKind
        public var offset: Int
        public var size: Int
    }

    public struct Layout: Hashable, Sendable {
        public var fields: [FieldLayout]
        public var totalSize: Int

        public init(fields: [FieldLayout], totalSize: Int) {
            self.fields = fields
            self.totalSize = totalSize
        }
    }

    /// Computes the layout for a sequence of uniform declarations.
    public static func compute(for uniforms: [UniformDecl]) -> Layout {
        var fields: [FieldLayout] = []
        var offset = 0
        var maxAlign = 1

        for uniform in uniforms {
            let (size, alignment) = sizeAndAlignment(of: uniform.kind)
            offset = roundUp(offset, to: alignment)
            fields.append(FieldLayout(name: uniform.name, kind: uniform.kind, offset: offset, size: size))
            offset += size
            maxAlign = max(maxAlign, alignment)
        }

        // Empty struct still emits one `int _unused;` field — match that size.
        if fields.isEmpty {
            return Layout(fields: [], totalSize: 4)
        }

        let totalSize = roundUp(offset, to: maxAlign)
        return Layout(fields: fields, totalSize: totalSize)
    }

    /// Packs values into a freshly-zeroed buffer of size `layout.totalSize`,
    /// looking up each field by name in `values`. Missing names use the
    /// supplied defaults.
    public static func pack(
        values: [String: UniformValue],
        defaults: [String: UniformValue],
        layout: Layout,
        into pointer: UnsafeMutableRawPointer
    ) {
        memset(pointer, 0, layout.totalSize)
        for field in layout.fields {
            let value = values[field.name] ?? defaults[field.name]
            guard let value else { continue }
            writeValue(value, kind: field.kind, into: pointer.advanced(by: field.offset))
        }
    }

    /// Convenience: builds a `[String: UniformValue]` from the declared defaults.
    public static func defaultsDictionary(_ uniforms: [UniformDecl]) -> [String: UniformValue] {
        Dictionary(uniqueKeysWithValues: uniforms.map { ($0.name, $0.defaultValue) })
    }

    // MARK: - Internals

    static func sizeAndAlignment(of kind: UniformKind) -> (size: Int, alignment: Int) {
        switch kind {
        case .float: return (4, 4)
        case .int: return (4, 4)
        case .bool: return (1, 1)
        case .float2: return (8, 8)
        case .float3: return (16, 16)
        case .float4, .color: return (16, 16)
        }
    }

    static func roundUp(_ value: Int, to alignment: Int) -> Int {
        guard alignment > 1 else { return value }
        let remainder = value % alignment
        return remainder == 0 ? value : value + (alignment - remainder)
    }

    static func writeValue(_ value: UniformValue, kind: UniformKind, into ptr: UnsafeMutableRawPointer) {
        switch (kind, value) {
        case (.float, .float(let scalar)):
            ptr.assumingMemoryBound(to: Float.self).pointee = scalar

        case (.int, .int(let scalar)):
            ptr.assumingMemoryBound(to: Int32.self).pointee = scalar

        case (.bool, .bool(let flag)):
            ptr.assumingMemoryBound(to: UInt8.self).pointee = flag ? 1 : 0

        case (.float2, .float2(let vector)):
            ptr.assumingMemoryBound(to: SIMD2<Float>.self).pointee = vector

        case (.float3, .float3(let vector)):
            // Store as float4 to satisfy MSL float3 stride; w stays zero.
            ptr.assumingMemoryBound(to: SIMD4<Float>.self).pointee = SIMD4<Float>(vector.x, vector.y, vector.z, 0)

        case (.float4, .float4(let vector)),
             (.color, .float4(let vector)):
            ptr.assumingMemoryBound(to: SIMD4<Float>.self).pointee = vector

        default:
            // Kind/value mismatch — leave zero. Caller's responsibility to
            // ensure consistency at construction time.
            break
        }
    }
}
