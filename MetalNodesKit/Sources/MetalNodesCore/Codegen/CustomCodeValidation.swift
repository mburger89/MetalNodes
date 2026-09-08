import Foundation

/// What user-written code is refused before it ever reaches the Metal compiler (spec §24.4): the
/// scope breakers, and the accessors a Custom MSL body cannot reach from where it is emitted.
/// Loops are hardened by codegen (Task 8) rather than refused, so this file stays small on purpose.
public enum CustomCodeValidation {
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // Expression formulas, in the root and in every definition's graph. `definition` stays
        // `nil` even for one nested inside a definition's `.graph` body: an Expression's own
        // association is always by `node`, never by `definition` — the same rule `LineMap.UserEntry`
        // follows for a compiled program (spec §24.4, Task 9).
        for node in allExpressionNodes(doc) {
            guard case .text(let formula)? = node.params[ExpressionNode.formulaParam] else { continue }
            out += MSLScanner.scopeBreakers(in: normalisedForScanning(formula)).map {
                Diagnostic(.error, message(for: $0), node: node.id, socket: ExpressionNode.formulaParam,
                          userLine: $0.line + 1)
            }
        }

        // Custom MSL bodies. A definition is checked whether or not it is instantiated: the user
        // is editing it now and should see the error now.
        for def in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            guard case .msl(let text) = def.body else { continue }
            out += MSLScanner.scopeBreakers(in: normalisedForScanning(text)).map {
                Diagnostic(.error, "\(def.name): \(message(for: $0))", userLine: $0.line + 1, definition: def.id)
            }
            // The third guard family (spec §24.5): an accessor the body's own environment cannot
            // reach. A `.msl` body is emitted as the *group function*'s body (`GroupCodegen`), and
            // that function's parameter list is `(float2 uv, float time, float2 size, float2 mouse,
            // …)` — one function serves every target and every caller, so `params` and `geo` are
            // not in scope there under *any* document target. Asking the target's own environment
            // instead would call `params.geometry().normal()` legal in a RealityKit document and
            // then emit a function that cannot compile; see this task's report.
            //
            // Filed against the definition and the user's own line, like the scope breakers above:
            // `EditorModel.codeDiagnostics` keeps a row whose `definition` is `nil` for *every*
            // open editor (a compile error on generated scaffolding has no better home), so a
            // definition-less accessor diagnostic would appear in every other definition's editor
            // at line 0. The line is the accessor chain's own, from the same scan the predicate's
            // answer came from.
            if case .missing(let accessor) = EmitEnvironment.groupFunction.canEmit(mslText: text) {
                let line = MSLScanner.accessorCallSites(in: normalisedForScanning(text))
                    .first { $0.chain == accessor }?.line
                out.append(Diagnostic(.error,
                    "\(def.name): \(accessor) is not available inside a group definition — read it in the root graph and pass the value in",
                    userLine: line.map { $0 + 1 }, definition: def.id))
            }
        }
        return out
    }

    /// `MSLScanner.tokenise` (shared, out of this file's scope to change) counts a physical line by
    /// `c == "\n"`, and Swift folds a `\r\n` pair into a single `Character` — so a Windows-pasted
    /// body would otherwise report every `Violation.line` as `0`, the same defect `Task 9` fixed at
    /// `LoopHardening.hardened`'s own boundary. Normalising a local copy here, purely for the
    /// scanner's line count, gets a correct `userLine` without touching `MSLScanner.swift` — the
    /// diagnostic's `node`/`socket`/message still describe the document's own, unmodified text.
    /// Internal rather than private so `MaterialValidation`'s custom-body rule scans the same
    /// normalised text and reports the same physical line this file would.
    static func normalisedForScanning(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
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
