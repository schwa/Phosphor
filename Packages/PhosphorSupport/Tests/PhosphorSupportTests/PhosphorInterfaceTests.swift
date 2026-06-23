import Testing
@testable import PhosphorCompile

struct PhosphorInterfaceTests {
    @Test("Interface keeps signatures but strips function bodies")
    func stripsBodies() {
        let iface = PhosphorInterface.source
        // Signatures present.
        #expect(iface.contains("float2x2 rotate2D(float angle);"))
        #expect(iface.contains("float snoise2D(float2 v);"))
        #expect(iface.contains("float3 hsv(float h, float s, float v);"))
        // No implementation tokens that only appear inside bodies.
        #expect(!iface.contains("return float2x2(c, -s, s, c)"))
        #expect(!iface.contains("0.211324865405187"))
        #expect(!iface.contains("inline "))
    }

    @Test("Interface keeps constants, macros, and typedefs verbatim")
    func keepsDeclarations() {
        let iface = PhosphorInterface.source
        #expect(iface.contains("constant float PI = 3.141592653589793;"))
        #expect(iface.contains("typedef float2 vec2;"))
        #expect(iface.contains("#define F4 0.309016994374947451"))
    }

    @Test("Doc comments survive")
    func keepsComments() {
        #expect(PhosphorInterface.source.contains("// 2D rotation matrix."))
    }
}
