import Testing
@testable import MetalNodesCore

@Suite struct TopoSortTests {
    @Test func sourcesComeBeforeConsumersAndTerminalIsLast() {
        let doc = ShaderDocument.sample()
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        #expect(order.last == terminal)
        var seen = Set<NodeID>()
        for id in order {
            for (to, from) in doc.root.inputs where to.node == id {
                #expect(seen.contains(from.node), "\(from.node) must precede \(id)")
            }
            seen.insert(id)
        }
        #expect(Set(order) == doc.root.upstreamNodes(of: terminal).union([terminal]))
    }

    @Test func unreachableNodesAreDropped() {
        var doc = ShaderDocument.sample()
        let orphan = NodeInstance(kind: .builtin("noise.value"))
        doc.root.nodes[orphan.id] = orphan
        let terminal = GraphValidator.terminal(in: doc.root)!
        #expect(!TopoSort.order(doc.root, from: terminal).contains(orphan.id))
    }

    @Test func orderIsDeterministic() {
        let doc = ShaderDocument.sample()
        let terminal = GraphValidator.terminal(in: doc.root)!
        let a = TopoSort.order(doc.root, from: terminal)
        let b = TopoSort.order(doc.root, from: terminal)
        #expect(a == b)
    }

    @Test func sharedSourceAppearsOnce() {
        let doc = ShaderDocument.sample()   // input.uv feeds two nodes
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        #expect(order.count == Set(order).count)
    }
}
