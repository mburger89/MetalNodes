import Testing
@testable import MetalNodesCore

@Suite struct GroupDependenciesTests {
    /// A ⊃ B ⊃ C (A's graph holds an instance of B, B's an instance of C).
    private func chain() -> (ShaderDocument, a: GroupID, b: GroupID, c: GroupID) {
        var a = GroupDefinition.make(name: "A"), b = GroupDefinition.make(name: "B"), c = GroupDefinition.make(name: "C")
        let ib = NodeInstance(kind: .group(b.id)); a.graph.nodes[ib.id] = ib
        let ic = NodeInstance(kind: .group(c.id)); b.graph.nodes[ic.id] = ic
        var doc = ShaderDocument()
        for d in [a, b, c] { doc.definitions[d.id] = d }
        let ia = NodeInstance(kind: .group(a.id)); doc.root.nodes[ia.id] = ia
        return (doc, a.id, b.id, c.id)
    }

    @Test func directAndTransitiveDependencies() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.direct(doc.definitions[a]!) == [b])
        #expect(GroupDependencies.transitive(a, in: doc) == [b, c])
        #expect(GroupDependencies.transitive(c, in: doc).isEmpty)
    }

    @Test func recursionIsRefusedDirectlyAndTransitively() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.wouldRecurse(placing: a, in: .definition(a), document: doc))
        #expect(GroupDependencies.wouldRecurse(placing: a, in: .definition(c), document: doc))   // C is inside A
        #expect(GroupDependencies.wouldRecurse(placing: b, in: .definition(c), document: doc))
        #expect(!GroupDependencies.wouldRecurse(placing: c, in: .definition(a), document: doc))
        #expect(!GroupDependencies.wouldRecurse(placing: a, in: .root, document: doc))
    }

    @Test func innerFirstOrderAndReachability() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.innerFirst([a, b, c], in: doc) == [c, b, a])
        #expect(GroupDependencies.reachable(from: doc.root, in: doc) == [a, b, c])
        #expect(GroupDependencies.reachable(from: doc.definitions[c]!.graph, in: doc).isEmpty)
    }
}
