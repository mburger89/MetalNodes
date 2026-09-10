import Foundation

public enum TopoSort {
    /// Every node's sources, each list in sorted-uuid order, built once per traversal so the
    /// walk is O(N + E) instead of a scan of every wire per visited node (spec §27.4).
    static func sourcesByNode(_ graph: Graph) -> [NodeID: [NodeID]] {
        var sets: [NodeID: Set<NodeID>] = [:]
        for (to, from) in graph.inputs where graph.nodes[from.node] != nil {
            sets[to.node, default: []].insert(from.node)
        }
        return sets.mapValues { $0.sorted { $0.raw.uuidString < $1.raw.uuidString } }
    }

    /// Post-order DFS upstream from `terminal`. Nodes not reachable from the
    /// terminal never appear, which is the spec's "DCE for free" (§9).
    public static func order(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
        order(graph, from: terminal, sources: sourcesByNode(graph))
    }

    private static func order(_ graph: Graph, from terminal: NodeID, sources: [NodeID: [NodeID]]) -> [NodeID] {
        var result: [NodeID] = []
        var done = Set<NodeID>()

        var stack: [(NodeID, [NodeID])] = [(terminal, sources[terminal] ?? [])]
        var onStack: Set<NodeID> = [terminal]
        while let top = stack.last {
            let n = top.0
            var pending = top.1
            if let next = pending.popLast() {
                stack[stack.count - 1] = (n, pending)
                if !done.contains(next) && !onStack.contains(next) {
                    onStack.insert(next)
                    stack.append((next, sources[next] ?? []))
                }
            } else {
                stack.removeLast()
                onStack.remove(n)
                if done.insert(n).inserted { result.append(n) }
            }
        }
        return result
    }

    /// Dependencies-first order over **every** node in `graph`, not just what's reachable from one
    /// terminal (spec §20.6: resolving boundary types needs every node typed, including ones with
    /// no path to any particular output). DFS from each node in sorted-uuid order, each node once.
    public static func orderAll(_ graph: Graph) -> [NodeID] {
        let sources = sourcesByNode(graph)
        var result: [NodeID] = []
        var done = Set<NodeID>()
        for id in graph.nodes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) where !done.contains(id) {
            for n in order(graph, from: id, sources: sources) where !done.contains(n) {
                done.insert(n)
                result.append(n)
            }
        }
        return result
    }
}
