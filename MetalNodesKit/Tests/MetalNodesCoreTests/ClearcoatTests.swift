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
}
