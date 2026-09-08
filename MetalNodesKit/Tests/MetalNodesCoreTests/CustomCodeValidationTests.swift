import Testing
@testable import MetalNodesCore

@Suite struct CustomCodeValidationTests {
    private func expressionDoc(_ formula: String) -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let e = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                             params: ["formula": .text(formula), "type": .enumCase("color")])
        g.nodes[t.id] = t; g.nodes[e.id] = e
        g.inputs[SocketRef(t.id, "color")] = SocketRef(e.id, "out")
        doc.root = g
        return doc
    }

    private func definitionDoc(_ body: String) -> ShaderDocument {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl(body)
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        doc.root = g
        return doc
    }

    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
    }

    @Test func aPreprocessorDirectiveInADefinitionIsRefused() {
        let d = errors(definitionDoc("#include <metal_stdlib>\nout = 1.0;"))
        #expect(d.contains { $0.message.lowercased().contains("include") })
    }

    @Test func anUnbalancedBraceIsRefused() {
        #expect(errors(definitionDoc("if (true) { out = 1.0;")).contains { $0.message.lowercased().contains("brace") })
    }

    @Test func aBareReturnIsRefused() {
        #expect(errors(definitionDoc("return;")).contains { $0.message.lowercased().contains("return") })
    }

    /// The fourth scope-breaker guard (controller ruling, Task 2): an unbraced loop body would
    /// silently relocate Task 8's inserted `break` into the enclosing scope, so it is refused just
    /// like the other three. The message tells the user what to do — add braces — rather than
    /// describing why Task 8 needs them.
    @Test func anUnbracedLoopBodyInADefinitionIsRefused() {
        let d = errors(definitionDoc("for (int i = 0; i < 4; i++) out += 1.0;"))
        #expect(d.contains { $0.message.lowercased().contains("brace") })
    }

    @Test func aBracedLoopBodyIsAccepted() {
        #expect(errors(definitionDoc("for (int i = 0; i < 4; i++) { out += 1.0; }")).isEmpty)
    }

    @Test func aWellFormedBodyIsAccepted() {
        #expect(errors(definitionDoc("if (true) { out = 1.0; } else { out = 2.0; }")).isEmpty)
    }

    /// The same guards apply to an Expression's formula, anchored on the node so the canvas can
    /// outline it.
    @Test func anExpressionFormulaIsGuardedAndAnchored() {
        let doc = expressionDoc("return a;")
        let d = errors(doc)
        #expect(d.contains { $0.message.lowercased().contains("return") })
        #expect(d.first { $0.message.lowercased().contains("return") }?.node != nil)
    }

    /// An Expression's formula anchors its diagnostic to the formula param specifically, so the
    /// canvas can outline the field the user is editing, not just the node.
    @Test func anExpressionFormulaDiagnosticAnchorsTheFormulaSocket() {
        let doc = expressionDoc("return a;")
        let d = errors(doc).first { $0.message.lowercased().contains("return") }
        #expect(d?.socket == ExpressionNode.formulaParam)
    }

    /// A Custom MSL definition is not an instance, so its diagnostic has no node to anchor to —
    /// it carries the definition's name in the message instead.
    @Test func aDefinitionDiagnosticNamesTheDefinitionInsteadOfAnchoringANode() {
        let d = errors(definitionDoc("return;")).first { $0.message.lowercased().contains("return") }
        #expect(d?.node == nil)
        #expect(d?.message.contains("W") == true)
    }

    @Test func anOrdinaryFormulaIsAccepted() {
        #expect(errors(expressionDoc("float4(1.0, 0.0, 0.0, 1.0)")).isEmpty)
    }

    /// Task 9 fix round 1 (MINOR 3): a scope-breaker diagnostic previously had no line at all —
    /// `userLine` was always `nil`, even though `MSLScanner.Violation.line` already carried the
    /// answer. A bare `return` on a definition's second line must report `userLine == 2` and
    /// `definition` set to that definition, so a bare `return`, a `#define`, or an unbalanced brace
    /// lands on the user's own line, not on no line at all.
    @Test func aDefinitionDiagnosticCarriesTheUsersLineNumber() {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("out = 1.0;\nreturn;")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        let d = errors(doc).first { $0.message.lowercased().contains("return") }
        #expect(d?.userLine == 2)
        #expect(d?.definition == def.id)
    }

    /// The same, for an Expression's own formula — anchored by `node` (already asserted above),
    /// never by `definition`, even when the Expression's diagnostic carries a line.
    @Test func anExpressionFormulaDiagnosticCarriesTheUsersLineNumber() {
        let doc = expressionDoc("return a;")
        let d = errors(doc).first { $0.message.lowercased().contains("return") }
        #expect(d?.userLine == 1)
        #expect(d?.definition == nil)
    }

    /// The CRLF defect Task 9 fixed at `LoopHardening.hardened`'s boundary has a twin here:
    /// `MSLScanner.tokenise` folds a `\r\n` pair into one `Character`, so without normalising the
    /// text handed to the scanner, this diagnostic would report line 0 for a violation that is
    /// really on the body's second physical line.
    @Test func aCRLFDefinitionBodyStillReportsThePhysicalLineNumber() {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("out = 1.0;\r\nreturn;")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        let d = errors(doc).first { $0.message.lowercased().contains("return") }
        #expect(d?.userLine == 2)
    }

    /// A definition nothing instantiates still validates — a broken body the user is mid-edit on
    /// should show its error, not hide until wired.
    @Test func anUninstantiatedDefinitionIsStillChecked() {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Orphan")
        def.body = .msl("#pragma once")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        #expect(errors(doc).contains { $0.message.lowercased().contains("pragma") })
    }

    /// The validator and codegen count the same lines: both trim the formula first (handoff T9).
    @Test func aFormulaWithLeadingNewlinesReportsTheTrimmedLine() {
        let d = CustomCodeValidation.diagnostics(document: expressionDoc("\n\nreturn a;"), registry: .builtin)
        #expect(d.count == 1)
        #expect(d.first?.userLine == 1)
    }
}

/// Final fix wave — F4 and F7.
@Suite struct CustomCodeValidationAnchoringTests {
    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
    }

    /// F4: the accessor diagnostic used to carry neither `definition` nor `userLine`, and
    /// `EditorModel.codeDiagnostics` keeps a definition-less row for *every* open editor — so
    /// definition A's `params.geometry()` error appeared in definition B's editor at line 0. It is
    /// now filed like the scope breakers: against its definition, on the chain's own line.
    @Test func anAccessorDiagnosticIsFiledAgainstItsDefinitionAndLine() throws {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("out = 1.0;\nout = params.geometry().normal().x;")
        doc.definitions[def.id] = def
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        doc.root.nodes[t.id] = t
        let d = try #require(errors(doc).first { $0.message.contains("params.geometry()") })
        #expect(d.definition == def.id)
        #expect(d.userLine == 2)
    }

    /// F7: an Expression inside a `.graph` definition is scanned for scope breakers exactly like
    /// one in the root — `allExpressionNodes` walks every definition's graph, and skipping that
    /// walk left the suite green. Anchored by `node`, never by `definition` (the rule
    /// `LineMap.UserEntry` follows too).
    @Test func anExpressionInsideAGraphDefinitionIsGuarded() throws {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "G", outputs: [SocketDecl(name: "out", type: .concrete(.float))])
        var inner = Graph()
        let gin = NodeInstance(kind: .groupInput, position: .zero)
        let gout = NodeInstance(kind: .groupOutput, position: .zero)
        let e = NodeInstance(kind: .builtin(ExpressionNode.id), position: .zero,
                             params: [ExpressionNode.formulaParam: .text("#include <metal_stdlib>"),
                                      "type": .enumCase("float")])
        for n in [gin, gout, e] { inner.nodes[n.id] = n }
        inner.inputs[SocketRef(gout.id, "out")] = SocketRef(e.id, "out")
        def.graph = inner
        doc.definitions[def.id] = def
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        doc.root.nodes[t.id] = t; doc.root.nodes[i.id] = i
        let d = try #require(errors(doc).first { $0.message.lowercased().contains("include") })
        #expect(d.node == e.id)
        #expect(d.socket == ExpressionNode.formulaParam)
        #expect(d.definition == nil)
    }
}
