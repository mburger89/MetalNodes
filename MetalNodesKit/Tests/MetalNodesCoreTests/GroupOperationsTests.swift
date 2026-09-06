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

    private func resolved(_ doc: ShaderDocument) -> [NodeID: ResolvedNode] { (try? ShaderGenerator.generate(doc))?.resolved ?? [:] }

    @Test func groupCutsTheBoundaryAndDedupesBySourceSocket() throws {
        let (doc, mul, sine, time, speed, comb) = sample()
        let r = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
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
        let r = try #require(GroupOperations.group([a.id, b.id], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: "Pair"))
        let def = r.document.definitions[r.definition]!
        #expect(def.inputs.count == 1 && def.inputs[0].name == "out")
        #expect(def.graph.inputs[SocketRef(a.id, "a")] == SocketRef(def.inputNode!, "out"))
        #expect(def.graph.inputs[SocketRef(b.id, "a")] == SocketRef(def.inputNode!, "out"))
    }

    @Test func groupThenUngroupIsIdentityModuloIDs() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let u = try #require(GroupOperations.ungroup(g.instance, in: .root, of: g.document))
        #expect(u.document.root.nodes.count == doc.root.nodes.count)
        #expect(u.document.root.inputs.count == doc.root.inputs.count)
        #expect(u.nodes.count == 2)
        // Same multiset of (kind, params) and same wiring shape.
        func signature(_ g: Graph) -> [String] {
            g.inputs.map { to, from in
                let tk = g.nodes[to.node]!.kind, fk = g.nodes[from.node]!.kind
                return "\(fk).\(from.socket)->\(tk).\(to.socket)"
            }.sorted()
        }
        #expect(signature(u.document.root) == signature(doc.root))
        #expect(u.document.definitions.count == 1)                    // the definition is kept (spec §20.6)
        #expect(try ShaderGenerator.generate(u.document).source == (try ShaderGenerator.generate(doc).source))
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

    @Test func makeUniqueRetargetsOnlyThatInstance() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
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
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
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
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let r = try #require(GroupOperations.removeSocket(g.definition, kind: .input, name: "time", in: g.document))
        #expect(r.definitions[g.definition]!.inputs.map(\.name) == ["out"])
        #expect(r.root.inputs[SocketRef(g.instance, "time")] == nil)
        #expect(r.definitions[g.definition]!.graph.inputs[SocketRef(mul, "a")] == nil)
        #expect(GraphValidator.validate(document: r, registry: reg, target: .fragment).isEmpty)
    }

    @Test func groupingRefusesPseudoNodesAndRecursion() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let def = g.document.definitions[g.definition]!
        #expect(GroupOperations.group([mul, def.inputNode!], in: .definition(g.definition), of: g.document, registry: reg, resolved: [:], name: nil) == nil)
        #expect(GroupOperations.group([mul], in: .definition(g.definition), of: g.document, registry: reg, resolved: [:], name: nil) != nil)  // nested group inside is fine
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
