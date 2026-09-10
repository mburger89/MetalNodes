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

    @Test func theReverseAdjacencyListsEverySourceInSortedOrder() {
        let doc = ShaderDocument.sample()
        let map = TopoSort.sourcesByNode(doc.root)
        for (to, from) in doc.root.inputs where doc.root.nodes[from.node] != nil {
            #expect(map[to.node]?.contains(from.node) == true)
        }
        for (_, sources) in map {
            #expect(sources == sources.sorted { $0.raw.uuidString < $1.raw.uuidString })
            #expect(Set(sources).count == sources.count)
        }
        #expect(map.values.allSatisfy { !$0.isEmpty })
    }

    @Test func orderIsUnchangedByTheAdjacencyRewrite() {
        // The pre-M11 walk, kept here as the reference the fast one must reproduce.
        func reference(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
            var result: [NodeID] = [], done = Set<NodeID>()
            func sources(of n: NodeID) -> [NodeID] {
                var s = Set<NodeID>()
                for (to, from) in graph.inputs where to.node == n && graph.nodes[from.node] != nil { s.insert(from.node) }
                return s.sorted { $0.raw.uuidString < $1.raw.uuidString }
            }
            var stack: [(NodeID, [NodeID])] = [(terminal, sources(of: terminal))]
            var onStack: Set<NodeID> = [terminal]
            while let top = stack.last {
                let n = top.0; var pending = top.1
                if let next = pending.popLast() {
                    stack[stack.count - 1] = (n, pending)
                    if !done.contains(next) && !onStack.contains(next) { onStack.insert(next); stack.append((next, sources(of: next))) }
                } else { stack.removeLast(); onStack.remove(n); if done.insert(n).inserted { result.append(n) } }
            }
            return result
        }
        // `SampleDocuments.all` does not exist (Library/SampleDocuments.swift only extends
        // ShaderDocument with individual factories) — exercise every document-shaped fixture the
        // library actually exposes, across both Library files.
        let docs = [
            ShaderDocument.sample(),
            ShaderDocument.starter(),
            ShaderDocument.textured(),
            ShaderDocument.realityKitMaterial(),
            ShaderDocument.customCodeSample(),
            ShaderDocument.sampleWithGroup(),
        ]
        for doc in docs {
            for graph in [doc.root] + doc.definitions.values.map(\.graph) {
                for id in graph.nodes.keys {
                    #expect(TopoSort.order(graph, from: id) == reference(graph, from: id))
                }
            }
        }
    }
}
