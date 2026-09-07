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
