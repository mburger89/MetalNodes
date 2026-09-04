import Foundation

public enum RegistryError: Error, Equatable {
    case duplicateID(String)
    case duplicateName(def: String, name: String)
    case unknownPlaceholder(def: String, placeholder: String)
    case undeclaredGeneric(def: String, name: String)
    case variantsParamNotEnum(def: String, param: String)
    case missingVariantCase(def: String, case: String)
}

/// Validated lookup table of node definitions.
public struct NodeRegistry: Sendable {
    private let defs: [String: NodeDef]

    public init(_ list: [NodeDef]) throws(RegistryError) {
        var table: [String: NodeDef] = [:]
        for def in list {
            if table[def.id] != nil { throw RegistryError.duplicateID(def.id) }
            try NodeRegistry.validate(def)
            table[def.id] = def
        }
        defs = table
    }

    public subscript(id: String) -> NodeDef? { defs[id] }
    public var all: [NodeDef] { defs.values.sorted { $0.id < $1.id } }

    nonisolated(unsafe) static let placeholderPattern = /\{(in|out|param|type)\.([A-Za-z_][A-Za-z0-9_]*)\}/

    private static func validate(_ def: NodeDef) throws(RegistryError) {
        var seen = Set<String>()
        for name in def.inputs.map(\.name) + def.outputs.map(\.name) + def.params.map(\.name) {
            if !seen.insert(name).inserted { throw RegistryError.duplicateName(def: def.id, name: name) }
        }
        for decl in def.inputs + def.outputs {
            if case .generic(let g) = decl.type, def.generics[g] == nil {
                throw RegistryError.undeclaredGeneric(def: def.id, name: g)
            }
        }
        switch def.body {
        case .template(let t):
            try checkPlaceholders(t, in: def)
        case .variants(let param, let table):
            guard let p = def.param(named: param), case .enumeration(let cases) = p.kind else {
                throw RegistryError.variantsParamNotEnum(def: def.id, param: param)
            }
            for c in cases where table[c] == nil { throw RegistryError.missingVariantCase(def: def.id, case: c) }
            for t in table.values { try checkPlaceholders(t, in: def) }
        case .custom:
            break
        }
    }

    private static func checkPlaceholders(_ template: String, in def: NodeDef) throws(RegistryError) {
        for m in template.matches(of: placeholderPattern) {
            let kind = String(m.1), name = String(m.2)
            let ok: Bool = switch kind {
            case "in": def.input(named: name) != nil
            case "out": def.output(named: name) != nil
            case "param": def.param(named: name) != nil
            case "type": def.generics[name] != nil
            default: false
            }
            if !ok { throw RegistryError.unknownPlaceholder(def: def.id, placeholder: "\(kind).\(name)") }
        }
    }
}
