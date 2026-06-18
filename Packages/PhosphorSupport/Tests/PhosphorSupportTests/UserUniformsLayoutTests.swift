import Foundation
import simd
import Testing
@testable import PhosphorSupport

@Suite("UserUniformsLayout")
struct UserUniformsLayoutTests {
    @Test("Empty uniforms → 4-byte placeholder size")
    func emptyLayout() {
        let layout = UserUniformsLayout.compute(for: [])
        #expect(layout.fields.isEmpty)
        #expect(layout.totalSize == 4)
    }

    @Test("Single float → 4 bytes")
    func singleFloat() {
        let layout = UserUniformsLayout.compute(for: [
            .init(name: "x", kind: .float, defaultValue: .float(0))
        ])
        #expect(layout.fields == [
            .init(name: "x", kind: .float, offset: 0, size: 4)
        ])
        #expect(layout.totalSize == 4)
    }

    @Test("Float + bool + float → bool's misalignment doesn't break next field")
    func mixedAlignment() {
        // float at 0 (size 4), bool at 4 (align 1, size 1), float at 8 (align 4 → next multiple).
        // Total = 12, rounded to maxAlign (4) = 12.
        let layout = UserUniformsLayout.compute(for: [
            .init(name: "a", kind: .float, defaultValue: .float(0)),
            .init(name: "b", kind: .bool, defaultValue: .bool(false)),
            .init(name: "c", kind: .float, defaultValue: .float(0))
        ])
        #expect(layout.fields[0].offset == 0)
        #expect(layout.fields[1].offset == 4)
        #expect(layout.fields[2].offset == 8)
        #expect(layout.totalSize == 12)
    }

    @Test("Float3 forces 16-byte alignment + size")
    func float3Alignment() {
        // float at 0 (size 4, pad to 16), float3 at 16 (size 16), total = 32.
        let layout = UserUniformsLayout.compute(for: [
            .init(name: "a", kind: .float, defaultValue: .float(0)),
            .init(name: "v", kind: .float3, defaultValue: .float3(.zero))
        ])
        #expect(layout.fields[0].offset == 0)
        #expect(layout.fields[1].offset == 16)
        #expect(layout.totalSize == 32)
    }

    @Test("Pack writes values into buffer at correct offsets")
    func packing() {
        let layout = UserUniformsLayout.compute(for: [
            .init(name: "intensity", kind: .float, defaultValue: .float(1.0)),
            .init(name: "tint", kind: .float3, defaultValue: .float3(.init(1, 0, 0))),
            .init(name: "enabled", kind: .bool, defaultValue: .bool(false))
        ])
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: layout.totalSize, alignment: 16)
        defer { buffer.deallocate() }

        let values: [String: UniformValue] = [
            "intensity": .float(2.5),
            "tint": .float3(.init(0.1, 0.2, 0.3)),
            "enabled": .bool(true)
        ]
        UserUniformsLayout.pack(
            values: values,
            defaults: UserUniformsLayout.defaultsDictionary(layout.fields.map { .init(name: $0.name, kind: $0.kind, defaultValue: .float(0)) }),
            layout: layout,
            into: buffer
        )

        // intensity at offset 0.
        let intensity = buffer.advanced(by: layout.fields[0].offset).load(as: Float.self)
        #expect(intensity == 2.5)
        // tint at offset 16 (padded), expanded to float4 — read as SIMD4 and check first 3 components.
        let tint = buffer.advanced(by: layout.fields[1].offset).load(as: SIMD4<Float>.self)
        #expect(tint.x == 0.1)
        #expect(tint.y == 0.2)
        #expect(tint.z == 0.3)
        // enabled at offset 32 (after float3 takes bytes 16..31).
        let enabled = buffer.advanced(by: layout.fields[2].offset).load(as: UInt8.self)
        #expect(enabled == 1)
    }

    @Test("Pack uses defaults when value is missing")
    func packingDefaults() {
        let layout = UserUniformsLayout.compute(for: [
            .init(name: "x", kind: .float, defaultValue: .float(7.5))
        ])
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: layout.totalSize, alignment: 16)
        defer { buffer.deallocate() }

        let defaults: [String: UniformValue] = ["x": .float(7.5)]
        UserUniformsLayout.pack(
            values: [:],
            defaults: defaults,
            layout: layout,
            into: buffer
        )
        let x = buffer.load(as: Float.self)
        #expect(x == 7.5)
    }
}
