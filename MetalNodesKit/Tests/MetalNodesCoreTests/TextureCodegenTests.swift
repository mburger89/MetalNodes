import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct TextureCodegenTests {
    let reg = NodeRegistry.builtin
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    /// UV → Texture Sample(asset A) → Output; a second Texture Sample of the same asset feeds nothing.
    private func doc() -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.assets[aid(1)] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let uv = NodeInstance(id: id(1), kind: .builtin("input.uv"))
        let s1 = NodeInstance(id: id(2), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let s2 = NodeInstance(id: id(3), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let mix = NodeInstance(id: id(4), kind: .builtin("color.mixcolor"), params: ["mode": .enumCase("mix")])
        let out = NodeInstance(id: id(5), kind: .builtin("output.fragment"))
        for n in [uv, s1, s2, mix, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s1.id, "uv"))
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s2.id, "uv"))
        d.root.connect(SocketRef(s1.id, "color"), to: SocketRef(mix.id, "a"))
        d.root.connect(SocketRef(s2.id, "color"), to: SocketRef(mix.id, "b"))
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        return d
    }

    @Test func fragmentBindsOneSlotPerAsset() throws {
        let s = try ShaderGenerator.generate(doc(), registry: reg)
        #expect(s.textures == [TextureSlot(index: 0, asset: aid(1))])
        #expect(s.source.contains("constant Uniforms &u [[buffer(0)]],\n                           texture2d<float> tex0 [[texture(0)]]) {"))
        #expect(s.source.contains("tex0.sample(mn_sampler, "))
        #expect(s.source.components(separatedBy: "tex0.sample(").count == 3)   // two samples, one slot
        #expect(s.source.contains("constexpr sampler mn_sampler(filter::linear, address::repeat);"))
    }

    @Test func unassignedSampleUsesTheNilSlot() throws {
        var d = doc()
        d.root.nodes[id(3)]!.params["asset"] = .asset(nil)
        let s = try ShaderGenerator.generate(d, registry: reg)
        // Slots follow emission order, which is a post-order DFS: the sample wired into `b` (id 3)
        // is emitted before the one wired into `a` (id 2), so the shared nil slot comes first.
        #expect(s.textures == [TextureSlot(index: 0, asset: nil), TextureSlot(index: 1, asset: aid(1))])
        #expect(s.source.contains("texture2d<float> tex1 [[texture(1)]]"))
    }

    @Test func documentsWithoutTexturesAreUnchanged() throws {
        let s = try ShaderGenerator.generate(.sample(), registry: reg)
        #expect(s.textures.isEmpty)
        #expect(!s.source.contains("texture2d"))
        #expect(!s.source.contains("mn_sampler"))
    }

    /// A one-node definition that samples asset 2, instantiated once in the root.
    /// The returned id is the Texture Sample *inside* the definition.
    private func groupDoc() -> (document: ShaderDocument, sample: NodeID) {
        var def = GroupDefinition.make(name: "Tex")
        def.outputs = [SocketDecl(name: "color", type: .concrete(.color))]
        let s = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        def.graph.nodes[s.id] = s
        def.graph.connect(SocketRef(s.id, "color"), to: SocketRef(def.outputNode!, "color"))
        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[inst.id] = inst; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(inst.id, "color"), to: SocketRef(out.id, "color"))
        return (d, s.id)
    }

    @Test func groupFunctionsTakeTextureParameters() throws {
        let g = try ShaderGenerator.generate(groupDoc().document, registry: reg)
        #expect(g.textures == [TextureSlot(index: 0, asset: aid(2))])
        #expect(g.source.contains("(float2 uv, float time, float2 size, float2 mouse, texture2d<float> t_20000000)"))
        #expect(g.source.contains("mn_g_Tex_"))
        #expect(g.source.contains(", tex0);"))                     // the call passes the slot
        #expect(g.source.contains("t_20000000.sample(mn_sampler, "))
    }

    @Test func layerEffectRefusesATextureSampleInsideAGroup() throws {
        // The export has only `layer`, which cannot bind to the group function's `texture2d<float>`
        // parameter — so the Layer Effect refuses a grouped sample even though it allows a root one.
        var (d, sample) = groupDoc()
        d.settings.target = .stitchable(.layerEffect)
        let diags = GraphValidator.validate(document: d, registry: reg, target: d.settings.target)
        #expect(diags.contains { $0.message == "Texture Sample inside a group needs the Fragment target" && $0.node == sample })
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(d, target: d.settings.target, registry: reg) }
    }

    @Test func colorEffectRefusesTextureSampleAndLayerEffectSamplesTheLayer() throws {
        var d = doc()
        d.settings.target = .stitchable(.colorEffect)
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(d, target: d.settings.target, registry: reg) }
        let diags = GraphValidator.validate(document: d, registry: reg, target: .stitchable(.colorEffect))
        #expect(diags.contains { $0.message == "Texture Sample needs the Layer Effect target" && $0.node == id(2) })
        d.settings.target = .stitchable(.layerEffect); d.settings.exportName = "fx"
        let s = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
        // `Layer::sample` is a `half4`; MSL will not widen it to the body's `float4` on its own.
        #expect(s.exportSource!.contains("float4(layer.sample(position))"))
        #expect(!s.exportSource!.contains("texture2d"))
        #expect(s.source.contains("tex0.sample(mn_sampler, "))     // the preview samples the asset
    }


    /// The Color/Distortion Effect refusal is a property of the target, not of each node: however
    /// many samples the document holds — including ones inside definitions, whose nodes the root
    /// canvas never shows — the reader is told once.
    @Test func colorEffectReportsTheTargetRefusalOnce() throws {
        var d = doc()                                   // two root-level Texture Samples
        var def = GroupDefinition.make(name: "Tex")     // and a third inside a definition
        def.outputs = [SocketDecl(name: "color", type: .concrete(.color))]
        let inner = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        def.graph.nodes[inner.id] = inner
        def.graph.connect(SocketRef(inner.id, "color"), to: SocketRef(def.outputNode!, "color"))
        d.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id))
        d.root.nodes[inst.id] = inst
        d.settings.target = .stitchable(.colorEffect)

        let message = "Texture Sample needs the Layer Effect target"
        let diags = GraphValidator.validate(document: d, registry: reg, target: d.settings.target)
        #expect(diags.filter { $0.message == message }.count == 1)
        #expect(diags.contains { $0.message == message && $0.node == id(2) })   // a node in the root

        do {
            _ = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
            Issue.record("expected the Color Effect to refuse a Texture Sample")
        } catch {
            guard case .invalid(let thrown) = error else { return }
            #expect(thrown.filter { $0.message == message }.count == 1)
        }
    }

    @Test func gradientAndCheckerAreOrdinaryColorNodes() throws {
        var d = ShaderDocument()
        let g = NodeInstance(kind: .builtin("texture.gradient")), c = NodeInstance(kind: .builtin("texture.checker"))
        let mix = NodeInstance(kind: .builtin("color.mixcolor")), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [g, c, mix, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(g.id, "color"), to: SocketRef(mix.id, "a"))
        d.root.connect(SocketRef(c.id, "color"), to: SocketRef(mix.id, "b"))
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d, registry: reg)
        #expect(s.textures.isEmpty)
        #expect(s.source.contains("mn_checker(") && s.source.contains("mn_gradient("))
        // angle, colorA, colorB (Gradient), scale, colorA, colorB (Checker), plus Mix Color's unwired factor.
        #expect(s.layout.fields.compactMap(\.path).count == 7)
    }

    @Test func manifestRoundTripsAndIsTolerant() throws {
        var s = DocumentSettings()
        s.assets[aid(1)] = AssetInfo(name: "x.jpg", pixelSize: CGSize(width: 10, height: 20), fileExtension: "jpg")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: data) == s)
        let legacy = #"{"previewSize":[512,512],"timeMode":"wallClock","fastMath":true,"target":{"fragment":{}},"exportName":"x"}"#
        let d = try? JSONDecoder().decode(DocumentSettings.self, from: Data(legacy.utf8))
        #expect(d?.assets.isEmpty == true)
    }
}
