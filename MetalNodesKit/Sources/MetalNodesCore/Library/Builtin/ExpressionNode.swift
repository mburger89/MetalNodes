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
        sockets(forNames: MSLScanner.identifiers(in: formula))
    }

    public static func generics(forFormula formula: String) -> [String: [SocketType]] {
        generics(forNames: MSLScanner.identifiers(in: formula))
    }

    /// `sockets(forFormula:)`'s body, taking the already-scanned identifier list so a caller with
    /// both sockets and generics to compute (`shape(for:)`) tokenises the formula once (spec §27.3).
    static func sockets(forNames names: [String]) -> [SocketDecl] {
        names.enumerated().map { i, name in
            SocketDecl(name: name, label: name, type: .generic("T\(i)"), default: .value(.float(0)))
        }
    }

    /// `generics(forFormula:)`'s body, taking the already-scanned identifier list — see `sockets(forNames:)`.
    static func generics(forNames names: [String]) -> [String: [SocketType]] {
        var out: [String: [SocketType]] = [:]
        for i in names.indices { out["T\(i)"] = BuiltinNodes.anyFloat }
        return out
    }

    /// The instance's formula as an emitter template: `a * 2.0` becomes `{out.out} = {in.a} * 2.0;`.
    /// Substitution goes through `MSLScanner.rewritingIdentifiers`, which replaces exactly the
    /// token occurrences `identifiers(in:)` would name — so `a` inside `saturate` is untouched and,
    /// unlike a `\b`-bounded regex, so is a real swizzle like `col.rgb` (`\b` is a Unicode word
    /// boundary, and `.` between letters does not break there, so a regex route silently never
    /// matches `col` in `col.rgb` at all).
    ///
    /// `userLines` is `LoopHardening.hardened`'s own origins array, unchanged in length: wrapping
    /// the hardened text in `{out.out} = … ;` only edits the *content* of the first and last line,
    /// never the line count, so index `i` of `userLines` still names the origin of line `i` of
    /// `text` (spec §24.4, Task 9). The formula field is `.text(multiline: false)`, so in the
    /// ordinary case there is exactly one user line and `userLines == [0]` — a single-line formula
    /// carries no *information* in that `0` beyond "this line is the user's own text"; the one case
    /// where it grows past one element is a formula that itself writes a full one-line braced loop
    /// (legal MSL, accepted by `MSLScanner.scopeBreakers`), which `LoopHardening` still hardens and
    /// therefore still splits across lines here exactly as it would inside a Custom MSL body.
    static func template(for node: NodeInstance) -> (text: String, userLines: [Int?]) {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        // A `//` comment at the end of the formula would otherwise swallow the `;` this template
        // appends (spec §27.3). Blanking keeps the line count, so `userLines` is unaffected.
        let stripped = MSLScanner.stripComments(MSLScanner.normalisedLineEndings(formula))
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        // Nothing was typed, so there is no user line to point a diagnostic at — `nil`, not `0`.
        guard !trimmed.isEmpty else { return ("{out.out} = 0.0;", [nil]) }
        let hardened = LoopHardening.hardened(trimmed)
        let body = MSLScanner.rewritingIdentifiers(in: hardened.text) { "{in.\($0)}" }
        return ("{out.out} = \(body);", hardened.userLines)
    }

    /// The shape of one instance: sockets from its formula, output from its type param.
    public static func shape(for node: NodeInstance) -> NodeShape {
        let formula: String = { if case .text(let s)? = node.params[formulaParam] { return s } else { return "" } }()
        let typeName: String = { if case .enumCase(let s)? = node.params[outputTypeParam] { return s } else { return "float" } }()
        let names = MSLScanner.identifiers(in: formula)
        return NodeShape(title: node.customTitle ?? def.title, category: def.category,
                         inputs: sockets(forNames: names),
                         outputs: [SocketDecl(name: "out", label: "Out", type: .concrete(socketType(named: typeName)))],
                         params: def.params,
                         generics: generics(forNames: names),
                         style: def.style)
    }
}

extension BuiltinNodes {
    static let expression: [NodeDef] = [ExpressionNode.def]
}
