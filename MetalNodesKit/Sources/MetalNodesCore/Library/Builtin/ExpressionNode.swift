import Foundation

/// The Expression node (spec §24.2): a one-line formula whose sockets are the identifiers it
/// names. Unlike a Custom MSL definition it is *not* reusable — the formula is instance data, so
/// two Expression nodes are independent, which is what you want for a one-liner.
public enum ExpressionNode {
    public static let id = "utility.expression"
    public static let formulaParam = "formula"
    public static let outputTypeParam = "type"

    /// The output types offered, in picker order.
    public static let outputTypes: [String] = ["float", "float2", "float3", "float4", "color", "int", "bool"]

    static func socketType(named n: String) -> SocketType {
        SocketType(rawValue: n) ?? .float
    }

    /// The registry entry. Its declared sockets are empty: the real ones are computed per instance
    /// by `shape(for:)`, because they depend on a parameter.
    static let def = NodeDef(
        id: id, title: "Expression", category: .utility,
        params: [
            ParamDecl(name: formulaParam, label: "Formula", kind: .text(multiline: false),
                      defaultValue: .text("")),
            ParamDecl(name: outputTypeParam, label: "Type", kind: .enumeration(outputTypes),
                      defaultValue: .enumCase("float")),
        ],
        // Never emitted: `Emitter` substitutes the instance's formula (Task 4).
        body: .template(""))

    /// One input per free identifier, in first-appearance order, each with its own generic.
    public static func sockets(forFormula formula: String) -> [SocketDecl] {
        MSLScanner.identifiers(in: formula).enumerated().map { i, name in
            SocketDecl(name: name, label: name, type: .generic("T\(i)"), default: .value(.float(0)))
        }
    }

    public static func generics(forFormula formula: String) -> [String: [SocketType]] {
        var out: [String: [SocketType]] = [:]
        for i in MSLScanner.identifiers(in: formula).indices { out["T\(i)"] = BuiltinNodes.anyFloat }
        return out
    }

    /// The instance's formula as an emitter template: `a * 2.0` becomes `{out.out} = {in.a} * 2.0;`.
    /// Substitution goes through `MSLScanner.rewritingIdentifiers`, which replaces exactly the
    /// token occurrences `identifiers(in:)` would name — so `a` inside `saturate` is untouched and,
    /// unlike a `\b`-bounded regex, so is a real swizzle like `col.rgb` (`\b` is a Unicode word
    /// boundary, and `.` between letters does not break there, so a regex route silently never
    /// matches `col` in `col.rgb` at all).
    static func template(for node: NodeInstance) -> String {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        let trimmed = formula.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "{out.out} = 0.0;" }
        // A one-line formula (the field is `.text(multiline: false)`) cannot contain a loop
        // today, so `LoopHardening` never actually fires on this path — but calling it costs
        // nothing and keeps the guarantee "every emitted loop is capped" true even if this field
        // ever grows into a multi-line body.
        let hardened = LoopHardening.harden(trimmed)
        let body = MSLScanner.rewritingIdentifiers(in: hardened) { "{in.\($0)}" }
        return "{out.out} = \(body);"
    }

    /// The shape of one instance: sockets from its formula, output from its type param.
    public static func shape(for node: NodeInstance) -> NodeShape {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        let typeName: String = { if case .enumCase(let s)? = node.params[outputTypeParam] { return s } else { return "float" } }()
        return NodeShape(title: node.customTitle ?? def.title, category: def.category,
                         inputs: sockets(forFormula: formula),
                         outputs: [SocketDecl(name: "out", label: "Out", type: .concrete(socketType(named: typeName)))],
                         params: def.params,
                         generics: generics(forFormula: formula),
                         style: def.style)
    }
}

extension BuiltinNodes {
    static let expression: [NodeDef] = [ExpressionNode.def]
}
