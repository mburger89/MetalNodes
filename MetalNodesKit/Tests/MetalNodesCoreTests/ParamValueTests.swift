import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct TextParamValueTests {
    @Test func textRoundTripsThroughCoding() throws {
        let v = ParamValue.text("sin(a * 6.28) * b")
        let back = try JSONDecoder().decode(ParamValue.self, from: try JSONEncoder().encode(v))
        #expect(back == v)
    }

    /// A formula is never a uniform: it has no socket type, so the layout builder skips it and
    /// `UniformImage` never tries to write bytes for it.
    @Test func textIsNotUniformable() {
        #expect(ParamValue.text("x").socketType == nil)
        #expect(ParamValue.text("x").isUniformable == false)
    }

    @Test func textSurvivesAnEmptyStringAndNewlines() throws {
        for s in ["", "a\nb", "  spaced  "] {
            let v = ParamValue.text(s)
            #expect(try JSONDecoder().decode(ParamValue.self, from: try JSONEncoder().encode(v)) == v)
        }
    }
}

@Suite struct ParamValueTests {
    @Test func aNonFiniteComponentIsZero() {
        #expect(ParamValue.float(.nan).finite == .float(0))
        #expect(ParamValue.float2(SIMD2(.infinity, 1)).finite == .float2(SIMD2(0, 1)))
        #expect(ParamValue.float4(SIMD4(1, -.infinity, .nan, 2)).finite == .float4(SIMD4(1, 0, 0, 2)))
        #expect(ParamValue.int(3).finite == .int(3))
        #expect(ParamValue.float(.nan).mslLiteral == "0.0")
        #expect(ParamValue.float3(SIMD3(.infinity, 0, 0)).mslLiteral == "float3(0.0, 0.0, 0.0)")
    }
}
