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
    @Test func aTextParamTakesTheRowsItNeeds() throws {
        let (m, id) = model(formula: "a + b")
        let shape = try #require(m.shape(of: m.document.root.nodes[id]!))
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
    ///
    /// Also proves the prune is *scoped to the edited node*: a second, unrelated pair of nodes is
    /// wired into a `math.math` socket also named "b" — a name that is not live on the edited
    /// node's new shape either. A prune predicate that checked only "is this socket name live
    /// on *some* node" (dropping the `$0.key.node != id` half of the filter) would delete that
    /// wire too, even though it belongs to a different node entirely; only the node-scoping
    /// distinguishes the two (Task 15 fix round 1, MINOR 4).
    @Test func aWireIntoADroppedSocketIsPruned() {
        let (m, id) = model(formula: "a + b")
        var src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        src.params["value"] = .float(2)
        m.apply(.addNode(src))
        m.apply(.connect(from: SocketRef(src.id, "out"), to: SocketRef(id, "b")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] != nil)

        var otherSrc = NodeInstance(kind: .builtin("input.float"), position: .zero)
        otherSrc.params["value"] = .float(3)
        let other = NodeInstance(kind: .builtin("math.math"), position: .zero)
        m.apply(.addNode(otherSrc))
        m.apply(.addNode(other))
        m.apply(.connect(from: SocketRef(otherSrc.id, "out"), to: SocketRef(other.id, "b")))

        m.apply(.setParam(id, ExpressionNode.formulaParam, .text("a * 2.0")))
        #expect(m.document.root.inputs[SocketRef(id, "b")] == nil)
        #expect(m.document.root.inputs[SocketRef(id, "a")] == nil)  // was never wired
        #expect(m.document.root.inputs[SocketRef(other.id, "b")] == SocketRef(otherSrc.id, "out"))  // untouched: different node
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
