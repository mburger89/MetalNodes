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

    /// The document's group definitions for "My Functions" (spec §20.8): a case-insensitive
    /// substring match on the name, sorted by name. An empty query returns all of them.
    static func filterDefinitions(_ query: String, in doc: ShaderDocument) -> [GroupDefinition] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return doc.definitions.values
            .filter { q.isEmpty || $0.name.lowercased().contains(q) }
            // Names are unique in practice; the id breaks any tie so the list never reorders itself.
            .sorted { ($0.name.lowercased(), $0.id.raw.uuidString) < ($1.name.lowercased(), $1.id.raw.uuidString) }
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
    /// Palette / inspector label. `rawValue.capitalized` would print "Sdf", and group definitions
    /// are called "My Functions" throughout the UI (spec §11.4, §20.8).
    var displayName: String {
        switch self {
        case .sdf: "SDF"
        case .group: "My Functions"
        default: rawValue.capitalized
        }
    }
}
