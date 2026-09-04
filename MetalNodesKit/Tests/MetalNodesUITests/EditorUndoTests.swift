import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorUndoTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func singleApplyIsOneUndoStep() {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv")
        m.apply(.moveNodes([uv.id: CGPoint(x: 99, y: 99)]))
        #expect(m.canUndo)
        #expect(m.undoManager.undoActionName == "Move")
        m.undo()
        #expect(m.document == original)
        #expect(m.canRedo)
        m.redo()
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 99, y: 99))
    }

    @Test func transactionCoalescesAGesture() {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv")
        m.beginTransaction("Move")
        for i in 1...5 { m.apply(.moveNodes([uv.id: CGPoint(x: CGFloat(i) * 10, y: 0)])) }
        #expect(!m.canUndo)                       // nothing registered until the gesture ends
        m.endTransaction()
        #expect(m.canUndo)
        m.undo()
        #expect(m.document == original)
        #expect(!m.canUndo)                       // exactly one step
    }

    @Test func nestedBeginJoinsTheOpenTransactionUntilTheOutermostEnd() {
        let m = model()
        let uv = node(m, "input.uv")
        m.beginTransaction("Outer")
        m.beginTransaction("Inner")
        m.apply(.moveNodes([uv.id: CGPoint(x: 1, y: 1)]))
        m.endTransaction()                        // closes Inner only
        #expect(!m.canUndo)
        #expect(m.isInTransaction)
        m.endTransaction()                        // closes Outer → one step
        #expect(m.canUndo)
        #expect(m.undoManager.undoActionName == "Outer")
        m.endTransaction()                        // unbalanced extra end is ignored
        #expect(!m.isInTransaction)
    }

    @Test func noOpTransactionRegistersNothing() {
        let m = model()
        m.beginTransaction("Nothing")
        m.endTransaction()
        #expect(!m.canUndo)
    }

    @Test func everyChangeKindRoundTripsThroughUndo() async {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv"), out = node(m, "output.fragment"), speed = node(m, "input.float")
        let fresh = NodeInstance(kind: .builtin("input.time"))
        var settings = m.document.settings; settings.fastMath = false
        let changes: [DocumentChange] = [
            .moveNodes([uv.id: CGPoint(x: 5, y: 5)]),
            .setParam(speed.id, "value", .float(0.9)),
            .setTitle(uv.id, "Coords"),
            .disconnect(SocketRef(out.id, "color")),
            .addNode(fresh),
            .removeNodes([speed.id]),
            .insert(nodes: [NodeInstance(kind: .builtin("input.time"))], edges: []),
            .setSettings(settings),
        ]
        for change in changes {
            m.apply(change)
            #expect(m.document != original, "\(change.undoName) changed nothing")
            m.undo()
            #expect(m.document == original, "\(change.undoName) did not undo cleanly")
        }
    }

    @Test func undoPrunesSelectionAndSchedulesCompile() async {
        let c = RecordingCompiler()
        let m = EditorModel(document: .sample(), compiler: c)
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        let fresh = NodeInstance(kind: .builtin("input.time"))
        m.apply(.addNode(fresh))
        m.viewState.selection = [fresh.id]
        await m.awaitIdle()
        m.undo()
        await m.awaitIdle()
        #expect(m.viewState.selection.isEmpty)
        #expect(await c.generations.count == 3)   // start, addNode, undo
    }

    @Test func undoIsIgnoredWhileATransactionIsOpen() {
        let m = model()
        let uv = node(m, "input.uv")
        let p0 = uv.position
        m.apply(.moveNodes([uv.id: CGPoint(x: 50, y: 50)]))     // commits a step
        m.beginTransaction("Move")
        m.apply(.moveNodes([uv.id: CGPoint(x: 99, y: 99)]))
        m.undo()
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 99, y: 99))
        #expect(m.isInTransaction)
        m.endTransaction()
        m.undo()
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 50, y: 50))
        m.undo()
        #expect(m.document.root.nodes[uv.id]?.position == p0)
    }

    @Test func menuEnablementFollowsCanvasFocus() {
        let m = model()
        #expect(m.canvasHasFocus == false)
        m.canvasHasFocus = true
        #expect(m.canvasHasFocus)
    }

    @Test func restoreNeverRegistersAnUndoStep() {
        let m = model()
        var doc = m.document
        doc.settings.fastMath = false
        m.apply(.restore(doc))
        #expect(!m.canUndo)
        #expect(m.document.settings.fastMath == false)
    }
}
