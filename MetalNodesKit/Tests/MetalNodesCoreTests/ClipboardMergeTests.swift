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
    }
}
