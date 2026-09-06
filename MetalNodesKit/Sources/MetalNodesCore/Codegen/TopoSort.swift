import Foundation

public enum TopoSort {
    /// Post-order DFS upstream from `terminal`. Nodes not reachable from the
    /// terminal never appear, which is the spec's "DCE for free" (§9).
    public static func order(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var done = Set<NodeID>()

        func sources(of n: NodeID) -> [NodeID] {
            var s = Set<NodeID>()
            for (to, from) in graph.inputs where to.node == n && graph.nodes[from.node] != nil { s.insert(from.node) }
            return s.sorted { $0.raw.uuidString < $1.raw.uuidString }
        }

        var stack: [(NodeID, [NodeID])] = [(terminal, sources(of: terminal))]
        var onStack: Set<NodeID> = [terminal]
        while let top = stack.last {
            let n = top.0
            var pending = top.1
            if let next = pending.popLast() {
                stack[stack.count - 1] = (n, pending)
                if !done.contains(next) && !onStack.contains(next) {
                    onStack.insert(next)
                    stack.append((next, sources(of: next)))
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
        var result: [NodeID] = []
        var done = Set<NodeID>()
        for id in graph.nodes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) where !done.contains(id) {
            for n in order(graph, from: id) where !done.contains(n) {
                done.insert(n)
                result.append(n)
            }
        }
        return result
    }
}
