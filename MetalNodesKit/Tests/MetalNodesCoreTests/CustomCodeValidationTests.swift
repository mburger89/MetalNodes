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
}
