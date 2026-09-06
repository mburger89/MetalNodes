import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct ClipboardMergeTests {
    private func docWithDef() -> (ShaderDocument, GroupDefinition, NodeID) {
        var def = GroupDefinition.make(name: "Fbm")
        def.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id)); doc.root.nodes[inst.id] = inst
        return (doc, def, inst.id)
    }

    @Test func extractCarriesReferencedDefinitionsAndSkipsPseudoNodes() {
        let (doc, def, inst) = docWithDef()
        let clip = GraphClipboard.extract([inst], from: doc.root, document: doc)
        #expect(clip.definitions.map(\.id) == [def.id])
        let inner = GraphClipboard.extract(Set(def.graph.nodes.keys), from: def.graph, document: doc)
        #expect(inner.nodes.isEmpty)                                   // only pseudo-nodes were selected
    }

    @Test func sameIdSameHashReuses() {
        let (doc, def, _) = docWithDef()
        let plan = ClipboardMerge.plan(definitions: [def], into: doc)
        #expect(plan.insert.isEmpty && plan.remap.isEmpty)
    }

    @Test func sameIdDifferentHashImportsUnderAFreshId() {
        let (doc, def, _) = docWithDef()
        var changed = def; changed.name = "Fbm tweaked"
        let plan = ClipboardMerge.plan(definitions: [changed], into: doc)
        #expect(plan.insert.count == 1 && plan.insert[0].id != def.id && plan.insert[0].name == "Fbm tweaked (imported)")
        #expect(plan.remap[def.id] == plan.insert[0].id)
        let pasted = ClipboardMerge.apply(plan, to: [NodeInstance(kind: .group(def.id))])
        #expect(pasted[0].kind == .group(plan.insert[0].id))
    }

    @Test func absentDefinitionIsInsertedAsIsAndNestedReferencesAreRemapped() {
        let (doc, def, _) = docWithDef()
        var other = GroupDefinition.make(name: "Wrap")
        let nested = NodeInstance(kind: .group(def.id)); other.graph.nodes[nested.id] = nested
        var changed = def; changed.name = "Fbm 2"
        let plan = ClipboardMerge.plan(definitions: [changed, other], into: doc)
        #expect(plan.insert.count == 2)
        let wrap = plan.insert.first { $0.name == "Wrap" }!
        #expect(wrap.graph.nodes[nested.id]?.kind == .group(plan.remap[def.id]!))   // the import's id, not the original
        #expect(plan.insert.contains { $0.id == other.id })                        // absent def keeps its own id
        #expect(plan.remap[other.id] == nil)                                        // and is never remapped
    }

    @Test func importedCopyReminsInnerNodeIds() {
        let (doc, def, _) = docWithDef()
        var changed = def
        changed.name = "Fbm tweaked"
        let gin = changed.inputNode!, gout = changed.outputNode!
        changed.graph.connect(SocketRef(gin, "in"), to: SocketRef(gout, "out"))
        let plan = ClipboardMerge.plan(definitions: [changed], into: doc)
        let copy = plan.insert[0]
        #expect(Set(copy.graph.nodes.keys).isDisjoint(with: Set(def.graph.nodes.keys)))
        #expect(copy.graph.nodes.count == changed.graph.nodes.count)
        #expect(copy.graph.inputs.count == changed.graph.inputs.count)
    }

    /// A wire whose source node is not in the graph is dropped by the copy, not force-unwrapped.
    @Test func duplicateDropsADanglingWire() {
        var def = GroupDefinition.make(name: "Fbm")
        def.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let real = NodeInstance(kind: .builtin("input.float"))
        def.graph.nodes[real.id] = real
        def.graph.connect(SocketRef(real.id, "out"), to: SocketRef(def.outputNode!, "v"))
        def.graph.inputs[SocketRef(real.id, "a")] = SocketRef(NodeID(), "out")     // source is gone
        let copy = def.duplicate(name: "Fbm 2")
        #expect(copy.graph.nodes.count == 3)
        #expect(copy.graph.inputs.count == 1)
        let map = Dictionary(uniqueKeysWithValues: copy.graph.nodes.values.map { ($0.kind, $0.id) })
        #expect(copy.graph.inputs[SocketRef(map[.groupOutput]!, "v")] == SocketRef(map[.builtin("input.float")]!, "out"))
    }
}
