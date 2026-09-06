import Foundation

/// Which definitions contain which (spec §4.6, §20.4).
public enum GroupDependencies {
    /// Definitions instantiated directly inside `def`.
    public static func direct(_ def: GroupDefinition) -> Set<GroupID> {
        Set(def.graph.nodes.values.compactMap { if case .group(let g) = $0.kind { return g } else { return nil } })
    }

    public static func transitive(_ id: GroupID, in doc: ShaderDocument) -> Set<GroupID> {
        var seen = Set<GroupID>(), stack = Array(doc.definitions[id].map(direct) ?? [])
        while let g = stack.popLast() {
            guard seen.insert(g).inserted else { continue }
            if let d = doc.definitions[g] { stack += direct(d) }
        }
        return seen
    }

    /// Would an instance of `target` inside the graph at `path` make some definition contain itself?
    public static func wouldRecurse(placing target: GroupID, in path: GraphPath, document doc: ShaderDocument) -> Bool {
        guard case .definition(let host) = path else { return false }
        return target == host || transitive(target, in: doc).contains(host)
    }

    /// Inner-most first: a definition follows everything it instantiates. Stable by id within a level.
    public static func innerFirst(_ ids: Set<GroupID>, in doc: ShaderDocument) -> [GroupID] {
        var out: [GroupID] = [], done = Set<GroupID>()
        func visit(_ g: GroupID) {
            guard !done.contains(g), let d = doc.definitions[g] else { return }
            done.insert(g)
            for dep in direct(d).sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) { visit(dep) }
            out.append(g)
        }
        for g in ids.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) { visit(g) }
        return out
    }

    /// Every definition instantiated in `graph`, transitively.
    public static func reachable(from graph: Graph, in doc: ShaderDocument) -> Set<GroupID> {
        var out = Set<GroupID>()
        for n in graph.nodes.values { if case .group(let g) = n.kind { out.insert(g); out.formUnion(transitive(g, in: doc)) } }
        return out
    }
}
