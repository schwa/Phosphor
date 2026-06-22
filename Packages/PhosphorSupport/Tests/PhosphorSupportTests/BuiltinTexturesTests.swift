import Testing
@testable import PhosphorSupport

struct BuiltinTexturesTests {
    @Test("Every registered built-in resolves to non-empty asset data")
    func allEntriesLoad() {
        for entry in BuiltinTextures.all {
            let asset = BuiltinTextures.asset(named: entry.name)
            #expect(asset != nil, "missing resource for \(entry.name)")
            #expect((asset?.data.count ?? 0) > 0)
        }
    }

    @Test("Built-in assets decode to images at their expected sizes")
    func decodeMandrill() {
        let mandrill = BuiltinTextures.asset(named: "builtin:mandrill")
        let size = mandrill?.pixelSize()
        #expect(size?.width == 512)
        #expect(size?.height == 512)
    }

    @Test("Namespace detection and prefix-optional lookup")
    func namespaceLookup() {
        #expect(BuiltinTextures.isBuiltin("builtin:mandrill"))
        #expect(!BuiltinTextures.isBuiltin("mandrill"))
        // Lookup works with or without the prefix.
        #expect(BuiltinTextures.entry(named: "mandrill")?.name == "builtin:mandrill")
        #expect(BuiltinTextures.entry(named: "builtin:noise-blue")?.id == "noise-blue")
    }

    @Test("Unknown names don't resolve")
    func unknownReturnsNil() {
        #expect(BuiltinTextures.asset(named: "builtin:does-not-exist") == nil)
        #expect(BuiltinTextures.asset(named: "not-a-builtin") == nil)
    }
}
