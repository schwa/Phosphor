import CollaborationKit
import Foundation
@testable import PhosphorGeneration
import PhosphorModel
import Testing

/// Guards the hand-written `writeConfiguration` JSON Schema against drift from
/// the runtime `PhosphorConfiguration` model (which lives in PhosphorKit, a
/// separate repo). Enum lists derived via `enumValues` are checked for exact
/// parity; the few deliberately curated lists are checked for subset; required
/// fields are checked against the decoder's actual defaulting.
@Suite("PhosphorConfigurationSchema parity")
struct PhosphorConfigurationSchemaTests {
    // MARK: JSONValue navigation helpers

    private func object(_ value: JSONValue?) -> [String: JSONValue]? {
        guard case .object(let fields)? = value else { return nil }
        return fields
    }

    private func strings(_ value: JSONValue?) -> [String]? {
        guard case .array(let items)? = value else { return nil }
        return items.compactMap { item in
            guard case .string(let s) = item else { return nil }
            return s
        }
    }

    /// Walks an object path through nested `.object` fields.
    private func at(_ path: [String], in root: JSONValue) -> JSONValue? {
        var current: JSONValue? = root
        for key in path {
            guard let fields = object(current) else { return nil }
            current = fields[key]
        }
        return current
    }

    private var schema: JSONValue { PhosphorConfigurationSchema.jsonSchema }

    private var configuration: JSONValue {
        at(["properties", "configuration"], in: schema)!
    }

    // MARK: Derived-enum exact parity

    @Test("texture format enum exactly matches PhosphorPixelFormat")
    func formatParity() {
        let schemaValues = Set(strings(at(["properties", "textures", "items", "properties", "format", "enum"], in: configuration)) ?? [])
        #expect(schemaValues == Set(PhosphorPixelFormat.allCases.map(\.rawValue)))
    }

    @Test("texture binding access enum lists only real TextureAccess cases")
    func accessParity() {
        // TextureAccess is not CaseIterable on the published model, so assert
        // every advertised value round-trips to a real case via RawRepresentable.
        let path = ["properties", "passes", "items", "properties", "textures", "items", "properties", "access", "enum"]
        let schemaValues = strings(at(path, in: configuration)) ?? []
        #expect(!schemaValues.isEmpty)
        for raw in schemaValues {
            #expect(TextureAccess(rawValue: raw) != nil, "schema advertises unknown access '\(raw)'")
        }
        // Current curation exposes the full set the model defines.
        #expect(Set(schemaValues) == ["read", "sample", "write", "readWrite"])
    }

    @Test("uniform kind enum exactly matches UniformKind")
    func kindParity() {
        let schemaValues = Set(strings(at(["properties", "uniforms", "items", "properties", "kind", "enum"], in: configuration)) ?? [])
        #expect(schemaValues == Set(UniformKind.allCases.map(\.rawValue)))
    }

    @Test("uniform gesture enum exactly matches UniformGesture")
    func gestureParity() {
        let schemaValues = Set(strings(at(["properties", "uniforms", "items", "properties", "gesture", "enum"], in: configuration)) ?? [])
        #expect(schemaValues == Set(UniformGesture.allCases.map(\.rawValue)))
    }

    // MARK: Curated-enum subset parity

    @Test("texture swap enum is a valid, deliberately curated subset of SwapTiming")
    func swapSubset() {
        let schemaValues = strings(at(["properties", "textures", "items", "properties", "swap", "enum"], in: configuration)) ?? []
        // Every advertised value must be a real model case (SwapTiming is not
        // CaseIterable on the published model; use RawRepresentable).
        for raw in schemaValues {
            #expect(SwapTiming(rawValue: raw) != nil, "schema advertises unknown swap '\(raw)'")
        }
        // The curation is deliberate: `immediate` is modeled but unimplemented
        // and intentionally withheld from the LLM-facing schema.
        #expect(Set(schemaValues) == ["none", "endOfFrame"])
        #expect(SwapTiming(rawValue: "immediate") != nil)
    }

    // MARK: Required-field parity with the decoder

    @Test("configuration requires exactly what the decoder demands (only output)")
    func requiredFieldsMatchDecoder() throws {
        let required = Set(strings(object(configuration)?["required"]) ?? [])
        #expect(required == ["output"])

        // The decoder accepts a config with only `output` present, defaulting
        // textures/passes/uniforms/flipY — proving the others are NOT required.
        let json = #"{ "output": "image" }"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PhosphorConfiguration.self, from: json)
        #expect(decoded.output == "image")
        #expect(decoded.textures.isEmpty)
        #expect(decoded.passes.isEmpty)
        #expect(decoded.uniforms.isEmpty)
        #expect(decoded.flipY == false)
    }
}
