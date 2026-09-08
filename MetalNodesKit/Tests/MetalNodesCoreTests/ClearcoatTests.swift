import Testing
@testable import MetalNodesCore

@Suite struct ClearcoatTests {
    private func document(_ model: MaterialLightingModel, wireClearcoatNormal: Bool = false) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = model
        doc.settings.exportName = "cc"
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.material"), position: .zero)
        var c = NodeInstance(kind: .builtin("input.float"), position: .zero)
        c.params["value"] = .float(0.7)
        g.nodes[t.id] = t; g.nodes[c.id] = c
        g.inputs[SocketRef(t.id, "clearcoat")] = SocketRef(c.id, "out")
        if wireClearcoatNormal {
            let n = NodeInstance(kind: .builtin("input.normal3d"), position: .zero)
            g.nodes[n.id] = n
            g.inputs[SocketRef(t.id, "clearcoatNormal")] = SocketRef(n.id, "normal")
        }
        doc.root = g
        return doc
    }

    @Test func theTerminalGainsThreeSockets() {
        let d = NodeRegistry.builtin["output.material"]!
        #expect(d.input(named: "clearcoat")?.type == .concrete(.float))
        #expect(d.input(named: "clearcoatRoughness")?.type == .concrete(.float))
        #expect(d.input(named: "clearcoatNormal")?.type == .concrete(.float3))
        #expect(BuiltinNodes.materialStages["clearcoat"] == .surface)
        #expect(BuiltinNodes.materialStages["clearcoatNormal"] == .surface)
    }

    @Test func theModelHasAClearcoatCase() {
        #expect(MaterialLightingModel.allCases.contains(.clearcoat))
        #expect(MaterialLightingModel.clearcoat.swiftCase == ".clearcoat")
    }

    /// The header is explicit: the three setters are ignored unless the model is clearcoat.
    @Test func theSettersAreEmittedOnlyUnderClearcoat() throws {
        let cc = try #require(ShaderGenerator.generate(document(.clearcoat), target: .realityKit).exportSource)
        #expect(cc.contains("set_clearcoat(half("))
        #expect(cc.contains("set_clearcoat_roughness(half("))

        let lit = try #require(ShaderGenerator.generate(document(.lit), target: .realityKit).exportSource)
        #expect(!lit.contains("set_clearcoat"))
    }

    @Test func clearcoatKeepsTheEightBaseSetters() throws {
        let cc = try #require(ShaderGenerator.generate(document(.clearcoat), target: .realityKit).exportSource)
        for s in ["set_base_color", "set_normal", "set_roughness", "set_metallic",
                  "set_emissive_color", "set_opacity", "set_ambient_occlusion", "set_specular"] {
            #expect(cc.contains(s), "\(s)")
        }
    }

    /// set_clearcoat_normal is iOS 18 / macOS 15+, unlike the rest of the surface API.
    @Test func theAvailabilityNoteAppearsOnlyWhenClearcoatNormalIsWired() throws {
        let wired = try ShaderExport.files(for: document(.clearcoat, wireClearcoatNormal: true))
        let metal = try #require(wired.first { $0.name.hasSuffix(".metal") })
        #expect(metal.contents.contains("iOS 18") || metal.contents.contains("macOS 15"))

        let bare = try ShaderExport.files(for: document(.clearcoat))
        let bareMetal = try #require(bare.first { $0.name.hasSuffix(".metal") })
        #expect(!bareMetal.contents.contains("iOS 18"))
    }

    @Test func thePreviewCarriesASecondLobeUnderClearcoat() throws {
        let cc = try ShaderGenerator.generate(document(.clearcoat), target: .realityKit).source
        #expect(cc.contains("mn_clearcoat"))
        let lit = try ShaderGenerator.generate(document(.lit), target: .realityKit).source
        #expect(!lit.contains("mn_clearcoat"))
    }

    /// Fix round 1: `set_clearcoat_normal` is the one setter whose *call*, not just the
    /// availability note about it, is gated on wiring — calling it with the baked default would
    /// still raise the deployment floor for a setter nobody asked for (spec §24.7 fix round 1). The
    /// other two clearcoat setters have no such trap and are unconditional, same as the eight base
    /// ones — `clearcoatKeepsTheEightBaseSetters`/`theSettersAreEmittedOnlyUnderClearcoat` above
    /// already cover those.
    @Test func theClearcoatNormalSetterIsEmittedOnlyWhenWired() throws {
        let bare = try #require(ShaderGenerator.generate(document(.clearcoat), target: .realityKit).exportSource)
        #expect(!bare.contains("set_clearcoat_normal("))

        let wired = try #require(ShaderGenerator.generate(document(.clearcoat, wireClearcoatNormal: true), target: .realityKit).exportSource)
        #expect(wired.contains("set_clearcoat_normal(half3("))
    }

    /// Fix round 1 (MINOR 4): `direct` carries a `* 3.0` key-light-intensity factor
    /// (`MaterialPreviewCodegen.fragmentBody`) and the clearcoat lobe must carry the same one —
    /// otherwise Clearcoat at full strength/zero roughness renders visibly *weaker* than the base
    /// specular it sits over, reading as a bug rather than an approximation.
    @Test func thePreviewClearcoatLobeMatchesTheKeyLightIntensity() throws {
        let cc = try ShaderGenerator.generate(document(.clearcoat), target: .realityKit).source
        #expect(cc.contains("mn_clearcoatLobe(nc, v, l, mnClearcoatStrength, mnClearcoatRoughness) * ndotl * 3.0"))
    }
}
