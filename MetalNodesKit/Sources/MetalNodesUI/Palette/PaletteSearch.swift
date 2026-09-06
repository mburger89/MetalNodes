import Foundation
import MetalNodesCore

/// Search and grouping for the palette and the ⇧A popover (spec §18.7).
enum PaletteSearch {
    private static let order: [NodeCategory: Int] = Dictionary(uniqueKeysWithValues: NodeCategory.allCases.enumerated().map { ($1, $0) })

    static func filter(_ query: String, in defs: [NodeDef]) -> [NodeDef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return defs.sorted { (order[$0.category]!, $0.title) < (order[$1.category]!, $1.title) }
        }
        func rank(_ d: NodeDef) -> Int? {
            let t = d.title.lowercased()
            if t.hasPrefix(q) { return 0 }
            if t.contains(q) { return 1 }
            if d.id.lowercased().contains(q) { return 2 }
            return nil
        }
        return defs.compactMap { d in rank(d).map { ($0, d) } }
            .sorted { ($0.0, $0.1.title) < ($1.0, $1.1.title) }
            .map(\.1)
    }

    static func grouped(_ defs: [NodeDef]) -> [(category: NodeCategory, defs: [NodeDef])] {
        NodeCategory.allCases.compactMap { c in
            let ds = defs.filter { $0.category == c }
            return ds.isEmpty ? nil : (c, ds)
        }
    }

    /// True if some input of `def` could accept a value of `type` (used to filter the wire-drop popover).
    static func acceptsInput(of type: SocketType, _ def: NodeDef) -> Bool {
        def.inputs.contains { decl in
            switch decl.type {
            case .concrete(let c): DropResolver.compatible(type, c)
            case .generic(let g): (def.generics[g] ?? []).contains { DropResolver.compatible(type, $0) }
            }
        }
    }
}

extension NodeCategory {
    /// Palette / inspector label. `rawValue.capitalized` would print "Sdf".
    var displayName: String {
        self == .sdf ? "SDF" : rawValue.capitalized
    }
}
