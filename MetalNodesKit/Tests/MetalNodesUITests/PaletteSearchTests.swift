import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct PaletteSearchTests {
    let all = NodeRegistry.builtin.all

    @Test func emptyQueryReturnsEverythingGroupedInCategoryOrder() {
        let r = PaletteSearch.filter("   ", in: all)
        #expect(r.count == all.count)
        #expect(r.first?.category == .input)
        let g = PaletteSearch.grouped(r)
        #expect(g.map(\.category) == [.input, .math, .vector, .sdf, .noise, .color, .utility, .output])
        #expect(g.allSatisfy { !$0.defs.isEmpty })
    }

    @Test func prefixBeatsContainsBeatsID() {
        let r = PaletteSearch.filter("mi", in: all).map(\.id)
        #expect(r.first == "math.mix")            // title "Mix" — prefix
        #expect(r.contains("math.smoothstep") == false)
    }

    @Test func idMatchesSurfaceLast() {
        let r = PaletteSearch.filter("vector", in: all).map(\.id)
        // "Vector 2"/"Vector 3" titles prefix-match first; the vector.* ids surface after, sorted by title.
        #expect(r == ["input.float2", "input.float3",
                      "vector.combine", "vector.dot", "vector.length", "vector.normalize", "vector.rotate2d", "vector.separate"])
    }

    @Test func caseInsensitive() {
        #expect(PaletteSearch.filter("VALUE NOISE", in: all).map(\.id) == ["noise.value"])
    }

    @Test func acceptsInputHonoursConversions() {
        let mix = NodeRegistry.builtin["math.mix"]!, uv = NodeRegistry.builtin["input.uv"]!, out = NodeRegistry.builtin["output.fragment"]!
        #expect(PaletteSearch.acceptsInput(of: .float2, mix))
        #expect(PaletteSearch.acceptsInput(of: .texture, mix) == false)
        #expect(PaletteSearch.acceptsInput(of: .float, uv) == false)        // no inputs at all
        #expect(PaletteSearch.acceptsInput(of: .float3, out))
    }

    @Test func transferRoundTripsAsJSON() throws {
        let t = NodeDefTransfer(defID: "noise.value")
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(NodeDefTransfer.self, from: data).defID == "noise.value")
    }
}
