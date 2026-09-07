import Foundation

/// What user-written code is refused before it ever reaches the Metal compiler (spec §24.4).
/// Only the scope breakers refuse: loops are hardened by codegen (Task 8) and accessor legality
/// is the environment's question (Task 11), so this file stays small on purpose.
public enum CustomCodeValidation {
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // Expression formulas, in the root and in every definition's graph.
        for node in allExpressionNodes(doc) {
            guard case .text(let formula)? = node.params[ExpressionNode.formulaParam] else { continue }
            out += MSLScanner.scopeBreakers(in: formula).map {
                Diagnostic(.error, message(for: $0), node: node.id, socket: ExpressionNode.formulaParam)
            }
        }

        // Custom MSL bodies. A definition is checked whether or not it is instantiated: the user
        // is editing it now and should see the error now.
        for def in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            guard case .msl(let text) = def.body else { continue }
            out += MSLScanner.scopeBreakers(in: text).map {
                Diagnostic(.error, "\(def.name): \(message(for: $0))")
            }
        }
        return out
    }

    static func message(for v: MSLScanner.Violation) -> String {
        switch v.kind {
        case .preprocessor(let name):
            "`#\(name)` is not allowed in custom code — it would reshape the whole generated program"
        case .unbalancedBrace:
            "Unbalanced brace — the body must open and close every block it starts"
        case .bareReturn:
            "`return` would exit the generated function early — assign the outputs instead"
        case .unbracedLoopBody:
            "A loop body must be wrapped in braces — for example `for (...) { ... }`"
        }
    }

    /// Every Expression instance in the root and in every definition's `.graph` body. A `.msl`
    /// definition has no canvas — its own text is checked separately, below — so only `.graph`
    /// bodies contribute here.
    private static func allExpressionNodes(_ doc: ShaderDocument) -> [NodeInstance] {
        var out = doc.root.nodes.values
            .filter { $0.kind == .builtin(ExpressionNode.id) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        for d in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            guard case .graph(let g) = d.body else { continue }
            out += g.nodes.values
                .filter { $0.kind == .builtin(ExpressionNode.id) }
                .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        }
        return out
    }
}
