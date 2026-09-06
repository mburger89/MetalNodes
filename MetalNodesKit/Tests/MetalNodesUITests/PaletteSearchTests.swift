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
        let back = try JSONDecoder().decode(NodeDefTransfer.self, from: data)
        #expect(back.defID == "noise.value")
        #expect(back.groupID == nil)
    }

    /// A "My Functions" row drags a `GroupID` instead of a builtin id (spec §20.8).
    @Test func transferCarriesAGroupIDInstead() throws {
        let g = GroupID()
        let data = try JSONEncoder().encode(NodeDefTransfer(groupID: g))
        let back = try JSONDecoder().decode(NodeDefTransfer.self, from: data)
        #expect(back.groupID == g)
        #expect(back.defID == nil)
    }

    @Test func categoryDisplayNamesUppercaseTheAcronym() {
        #expect(NodeCategory.sdf.displayName == "SDF")
        #expect(NodeCategory.noise.displayName == "Noise")
        #expect(NodeCategory.group.displayName == "My Functions")
    }

    @Test func filterDefinitionsIsCaseInsensitiveSubstringSortedByName() {
        var doc = ShaderDocument()
        for n in ["Turbulence", "Fbm", "fbm helper"] {
            let d = GroupDefinition.make(name: n)
            doc.definitions[d.id] = d
        }
        #expect(PaletteSearch.filterDefinitions("  ", in: doc).map(\.name) == ["Fbm", "fbm helper", "Turbulence"])
        #expect(PaletteSearch.filterDefinitions("FBM", in: doc).map(\.name) == ["Fbm", "fbm helper"])
        #expect(PaletteSearch.filterDefinitions("bul", in: doc).map(\.name) == ["Turbulence"])
        #expect(PaletteSearch.filterDefinitions("zzz", in: doc).isEmpty)
    }
}
