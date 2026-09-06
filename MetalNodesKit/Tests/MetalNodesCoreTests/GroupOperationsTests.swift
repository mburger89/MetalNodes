import Foundation
import CoreGraphics
import Testing
@testable import MetalNodesCore

@Suite struct GroupOperationsTests {
    let reg = NodeRegistry.builtin

    /// The M1 sample; select {mul, sine} (Time and Float feed mul; sine feeds Combine.z).
    private func sample() -> (ShaderDocument, mul: NodeID, sine: NodeID, time: NodeID, speed: NodeID, comb: NodeID) {
        let doc = ShaderDocument.sample()
        func find(_ id: String, _ op: String? = nil) -> NodeID {
            doc.root.nodes.values.first { $0.kind == .builtin(id) && (op == nil || $0.params["op"] == .enumCase(op!)) }!.id
        }
        return (doc, find("math.math", "multiply"), find("math.math", "sine"), find("input.time"), find("input.float"), find("vector.combine"))
    }

    @Test func groupCutsTheBoundaryAndDedupesBySourceSocket() throws {
        let (doc, mul, sine, time, speed, comb) = sample()
        let r = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        let def = r.document.definitions[r.definition]!
        #expect(def.name == "Group")
        #expect(def.inputs.map(\.name) == ["time", "out"])           // Time.time and Float.out — one each
        #expect(def.inputs.map { GroupCodegen.concrete($0.type) } == [.float, .float])
        #expect(def.outputs.map(\.name) == ["out"])                    // sine.out → Combine.z
        #expect(def.graph.nodes.count == 4)                            // 2 nodes + 2 pseudo
        // Rewired externally:
        #expect(r.document.root.inputs[SocketRef(r.instance, "time")] == SocketRef(time, "time"))
        #expect(r.document.root.inputs[SocketRef(r.instance, "out")] == SocketRef(speed, "out"))
        #expect(r.document.root.inputs[SocketRef(comb, "z")] == SocketRef(r.instance, "out"))
        #expect(r.document.root.nodes[mul] == nil && r.document.root.nodes[sine] == nil)
        // Internally: GroupInput.time → mul.a, GroupInput.out → mul.b, mul.out → sine.a, sine.out → GroupOutput.out.
        #expect(def.graph.inputs[SocketRef(mul, "a")] == SocketRef(def.inputNode!, "time"))
        #expect(def.graph.inputs[SocketRef(def.outputNode!, "out")] == SocketRef(sine, "out"))
        #expect(GraphValidator.validate(document: r.document, registry: reg, target: .fragment).isEmpty)
        #expect(try ShaderGenerator.generate(r.document).source.contains("mn_g_Group_"))
    }

    @Test func oneExternalSourceFeedingTwoSelectedNodesIsOneInput() throws {
        var doc = ShaderDocument()
        let src = NodeInstance(kind: .builtin("input.float")), a = NodeInstance(kind: .builtin("math.math")), b = NodeInstance(kind: .builtin("math.math"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [src, a, b, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(a.id, "a"))
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(b.id, "a"))
        doc.root.connect(SocketRef(a.id, "out"), to: SocketRef(out.id, "color"))
        let r = try #require(GroupOperations.group([a.id, b.id], in: .root, of: doc, registry: reg, name: "Pair"))
        let def = r.document.definitions[r.definition]!
        #expect(def.inputs.count == 1 && def.inputs[0].name == "out")
        #expect(def.graph.inputs[SocketRef(a.id, "a")] == SocketRef(def.inputNode!, "out"))
        #expect(def.graph.inputs[SocketRef(b.id, "a")] == SocketRef(def.inputNode!, "out"))
    }

    @Test func groupThenUngroupIsIdentityModuloIDs() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        let u = try #require(GroupOperations.ungroup(g.instance, in: .root, of: g.document))
        #expect(u.document.root.nodes.count == doc.root.nodes.count)     // same node count
        #expect(u.document.root.inputs.count == doc.root.inputs.count)   // same edge count
        #expect(u.nodes.count == 2)
        // Same wiring shape.
        func signature(_ g: Graph) -> [String] {
            g.inputs.map { to, from in
                let tk = g.nodes[to.node]!.kind, fk = g.nodes[from.node]!.kind
                return "\(fk).\(from.socket)->\(tk).\(to.socket)"
            }.sorted()
        }
        #expect(signature(u.document.root) == signature(doc.root))
        // Same multiset of (kind, params) across root nodes — a structural comparison, not a text
        // comparison: generated MSL's SSA numbering depends on `TopoSort.order`'s uuid tie-break,
        // which shifts once `ungroup` mints fresh node ids, so comparing `source` strings is flaky
        // (controller ruling R10).
        func nodeSignature(_ doc: ShaderDocument) -> [String] {
            doc.root.nodes.values.map { n in
                let params = n.params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
                return "\(n.kind)|\(params)"
            }.sorted()
        }
        #expect(nodeSignature(u.document) == nodeSignature(doc))
        #expect(u.document.definitions.count == 1)                    // the definition is kept (spec §20.6)
        // Both still generate without throwing and agree on the shader's uniform shape.
        let originalLayout = try ShaderGenerator.generate(doc).layout
        let ungroupedLayout = try ShaderGenerator.generate(u.document).layout
        #expect(ungroupedLayout.fields.count == originalLayout.fields.count)
    }

    @Test func ungroupCarriesUnwiredExposedValuesOntoTheInlinedNodes() throws {
        var def = GroupDefinition.make(name: "G")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let m = NodeInstance(kind: .builtin("math.math"))
        def.graph.nodes[m.id] = m
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(m.id, "a"))
        def.graph.connect(SocketRef(m.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), params: ["x": .float(7)]), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[inst.id] = inst; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        let u = try #require(GroupOperations.ungroup(inst.id, in: .root, of: doc))
        let inlined = u.document.root.nodes[u.nodes.first!]!
        #expect(inlined.params["a"] == .float(7))
        #expect(u.document.root.inputs[SocketRef(out.id, "color")]?.node == inlined.id)
    }

    /// M2 fix: a `GroupOutput` fed straight from `GroupInput` (no real node in between) must not
    /// drop the wire on ungroup — the external target picks up whatever fed the instance's input.
    @Test func ungroupPreservesAPassThroughWire() throws {
        var def = GroupDefinition.make(name: "PassThrough")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let speed = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(0.5)])
        let inst = NodeInstance(kind: .group(def.id))
        let sink = NodeInstance(kind: .builtin("output.fragment"))
        for n in [speed, inst, sink] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(speed.id, "out"), to: SocketRef(inst.id, "x"))
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(sink.id, "color"))
        let u = try #require(GroupOperations.ungroup(inst.id, in: .root, of: doc))
        #expect(u.document.root.inputs[SocketRef(sink.id, "color")] == SocketRef(speed.id, "out"))
        #expect(u.nodes.isEmpty)   // a pure pass-through has no real node to inline
    }

    /// M4 fix: an *unwired* pass-through has no source to point the external target at, so the
    /// instance's stored value (else the declared default) lands on that target's own input param
    /// instead of the downstream node reverting to its own default.
    @Test func ungroupCarriesAnUnwiredPassThroughValueOntoTheExternalTarget() throws {
        var def = GroupDefinition.make(name: "PassThrough")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), params: ["x": .float(7)])
        let sink = NodeInstance(kind: .builtin("output.fragment"))
        for n in [inst, sink] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(sink.id, "color"))
        let u = try #require(GroupOperations.ungroup(inst.id, in: .root, of: doc))
        #expect(u.document.root.nodes[sink.id]?.params["color"] == .float(7))
        #expect(u.document.root.inputs[SocketRef(sink.id, "color")] == nil)
    }

    /// With nothing stored on the instance the declared default is what carries over.
    @Test func ungroupCarriesAPassThroughDefaultWhenTheInstanceStoredNothing() throws {
        var def = GroupDefinition.make(name: "PassThrough")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id))
        let sink = NodeInstance(kind: .builtin("output.fragment"))
        for n in [inst, sink] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(sink.id, "color"))
        let u = try #require(GroupOperations.ungroup(inst.id, in: .root, of: doc))
        #expect(u.document.root.nodes[sink.id]?.params["color"] == .float(1))
    }

    /// I2 fix: exposed socket types come from resolving the whole graph at `path`, not a `.float`
    /// fallback — a non-float boundary must keep its real type.
    @Test func exposedSocketTypesComeFromResolutionNotAFloatFallback() throws {
        var doc = ShaderDocument()
        let uv = NodeInstance(kind: .builtin("input.uv"))
        let sep = NodeInstance(kind: .builtin("vector.separate"))
        let comb = NodeInstance(kind: .builtin("vector.combine"))
        for n in [uv, sep, comb] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(sep.id, "v"))          // float2 → float3 (widened at emission)
        doc.root.connect(SocketRef(sep.id, "x"), to: SocketRef(comb.id, "x"))
        doc.root.connect(SocketRef(sep.id, "y"), to: SocketRef(comb.id, "y"))
        doc.root.connect(SocketRef(sep.id, "z"), to: SocketRef(comb.id, "z"))
        let r = try #require(GroupOperations.group([sep.id], in: .root, of: doc, registry: reg, name: nil))
        let def = r.document.definitions[r.definition]!
        #expect(def.inputs.map { GroupCodegen.concrete($0.type) } == [.float2])   // UV's own output type, not the destination's
        #expect(def.outputs.map { GroupCodegen.concrete($0.type) } == [.float, .float, .float])
    }

    /// I2 fix: resolution works over the graph *inside a definition* too — a boundary source that
    /// is a `GroupInput` pseudo-node must resolve to the enclosing definition's declared type.
    @Test func exposedSocketTypeResolvesInsideADefinition() throws {
        var def = GroupDefinition.make(name: "D")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0)))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("multiply")])
        def.graph.nodes[math.id] = math
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(math.id, "a"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let r = try #require(GroupOperations.group([math.id], in: .definition(def.id), of: doc, registry: reg, name: nil))
        let inner = r.document.definitions[r.definition]!
        #expect(inner.inputs.map { GroupCodegen.concrete($0.type) } == [.float])
    }

    @Test func makeUniqueRetargetsOnlyThatInstance() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        var d = g.document
        let second = NodeInstance(kind: .group(g.definition), position: CGPoint(x: 900, y: 900))
        d.root.nodes[second.id] = second
        let m = try #require(GroupOperations.makeUnique(second.id, in: .root, of: d))
        #expect(m.definition != g.definition)
        #expect(m.document.definitions[m.definition]?.name == "Group 2")
        #expect(m.document.root.nodes[second.id]?.kind == .group(m.definition))
        #expect(m.document.root.nodes[g.instance]?.kind == .group(g.definition))
        let ids = Set(m.document.definitions[m.definition]!.graph.nodes.keys), orig = Set(m.document.definitions[g.definition]!.graph.nodes.keys)
        #expect(ids.isDisjoint(with: orig))
    }

    @Test func renameSocketRewritesEveryReference() throws {
        let (doc, mul, sine, time, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        let r = try #require(GroupOperations.renameSocket(g.definition, kind: .input, from: "time", to: "t", in: g.document))
        let def = r.definitions[g.definition]!
        #expect(def.inputs.map(\.name) == ["t", "out"])
        #expect(r.root.inputs[SocketRef(g.instance, "t")] == SocketRef(time, "time") && r.root.inputs[SocketRef(g.instance, "time")] == nil)
        #expect(def.graph.inputs[SocketRef(mul, "a")] == SocketRef(def.inputNode!, "t"))
        #expect(GroupOperations.renameSocket(g.definition, kind: .input, from: "t", to: "out", in: r) == nil)   // clash
        #expect(GroupOperations.renameSocket(g.definition, kind: .input, from: "t", to: "2 bad", in: r)?.definitions[g.definition]?.inputs.first?.name == "_2_bad")
    }

    @Test func removeSocketDeletesOrphansEverywhere() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        let r = try #require(GroupOperations.removeSocket(g.definition, kind: .input, name: "time", in: g.document))
        #expect(r.definitions[g.definition]!.inputs.map(\.name) == ["out"])
        #expect(r.root.inputs[SocketRef(g.instance, "time")] == nil)
        #expect(r.definitions[g.definition]!.graph.inputs[SocketRef(mul, "a")] == nil)
        #expect(GraphValidator.validate(document: r, registry: reg, target: .fragment).isEmpty)
    }

    @Test func groupingRefusesPseudoNodesAndRecursion() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, name: nil))
        let def = g.document.definitions[g.definition]!
        #expect(GroupOperations.group([mul, def.inputNode!], in: .definition(g.definition), of: g.document, registry: reg, name: nil) == nil)
        #expect(GroupOperations.group([mul], in: .definition(g.definition), of: g.document, registry: reg, name: nil) != nil)  // nested group inside is fine
    }

    @Test func namesAreUnique() {
        var doc = ShaderDocument()
        let a = GroupDefinition.make(name: "Group"); doc.definitions[a.id] = a
        #expect(GroupOperations.uniqueDefinitionName("Group", in: doc) == "Group 2")
        #expect(GroupOperations.uniqueSocketName("out", among: ["out", "out2"]) == "out3")
        #expect(GroupOperations.isUsed(a.id, in: doc) == false)
        #expect(GroupOperations.deleteDefinition(a.id, in: doc)?.definitions.isEmpty == true)
    }
}
