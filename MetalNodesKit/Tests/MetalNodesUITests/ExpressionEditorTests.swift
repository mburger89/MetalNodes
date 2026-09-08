import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

// `RecordingCompiler` is declared in `EditorModelTests.swift` — same test target, so it is
// visible here. Do not declare a second one.
@Suite @MainActor struct ExpressionEditorTests {
    private func model(formula: String) -> (EditorModel, NodeID) {
        var doc = ShaderDocument()
        var e = NodeInstance(kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text(formula)
        doc.root.nodes[e.id] = e
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        return (m, e.id)
    }

    @Test func theFormulaParamShowsInTheBody() {
        let decl = ExpressionNode.def.params.first { $0.name == ExpressionNode.formulaParam }
        #expect(decl?.showsInBody == true)
        if case .text(let multiline)? = decl?.kind { #expect(multiline == false) }
        else { Issue.record("formula is not a text param") }
    }

    /// A single-line text param takes exactly one row, like any other body param.
    @Test func aTextParamTakesTheRowsItNeeds() {
        let (m, id) = model(formula: "a + b")
        let shape = m.shape(of: m.document.root.nodes[id]!)!
        // 2 inputs (a, b) + 2 body params (formula, type) + 1 output
        #expect(NodeGeometry.bodyRows(shape) == 5)
    }

    /// Editing the formula is a topology change: it adds and removes sockets.
    @Test func editingTheFormulaReshapesTheNode() {
        let (m, id) = model(formula: "a + b")
        #expect(m.shape(of: m.document.root.nodes[id]!)?.inputs.map(\.name) == ["a", "b"])
        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a * c")))
        #expect(m.shape(of: m.document.root.nodes[id]!)?.inputs.map(\.name) == ["a", "c"])
        #expect(m.undoManager.canUndo)
    }

    /// The wire into `b` has nowhere to land once `b` is gone. Leaving it would put an edge in the
    /// document naming a socket no shape declares — exactly the corruption class M7 closed.
    @Test func aWireIntoADroppedSocketIsPruned() {
        let (m, id) = model(formula: "a + b")
        var src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        src.params["value"] = .float(2)
        m.apply(.addNode(src))
        m.apply(.connect(from: SocketRef(src.id, "out"), to: SocketRef(id, "b")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] != nil)

        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a * 2.0")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] == nil)
        #expect(m.document.root.inputs[SocketRef(id, "a")] == nil)  // was never wired
    }

    /// Undo restores both the formula and the wire it dropped.
    @Test func undoRestoresThePrunedWire() {
        let (m, id) = model(formula: "a + b")
        var src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        src.params["value"] = .float(2)
        m.apply(.addNode(src))
        m.apply(.connect(from: SocketRef(src.id, "out"), to: SocketRef(id, "b")))
        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a")))
        m.undo()
        #expect(m.document.root.inputs[SocketRef(id, "b")] == SocketRef(src.id, "out"))
    }

    /// The field's own error text: diagnostics filed against the formula socket.
    @Test func diagnosticsFilterToTheFormulaSocket() {
        let (m, id) = model(formula: "a + b")
        m.diagnostics = [
            Diagnostic(.error, "use of undeclared identifier 'qq'", node: id,
                       socket: ExpressionNode.formulaParam),
            Diagnostic(.warning, "unrelated", node: id),
        ]
        let onField = m.diagnostics(for: id, socket: ExpressionNode.formulaParam)
        #expect(onField.count == 1)
        #expect(onField.first?.message.contains("qq") == true)
        #expect(m.diagnostics(for: id, socket: nil).count == 2)
    }
}
