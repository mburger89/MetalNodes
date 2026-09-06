import Testing
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorSelectionTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func selectModes() {
        let m = model()
        let a = node(m, "input.uv").id, b = node(m, "input.time").id
        m.select(a)
        #expect(m.selection == [a])
        m.select(b, mode: .add)
        #expect(m.selection == [a, b])
        m.select(a, mode: .toggle)
        #expect(m.selection == [b])
        m.select(a)
        #expect(m.selection == [a])
        m.selectAll()
        #expect(m.selection.count == 11)
        m.clearSelection()
        #expect(m.selection.isEmpty)
    }

    @Test func selectingANodeClearsAWireSelection() {
        let m = model()
        let out = node(m, "output.fragment").id
        m.selectedWire = SocketRef(out, "color")
        m.select(node(m, "input.uv").id)
        #expect(m.selectedWire == nil)
    }

    @Test func deleteSelectionRemovesNodesAsOneUndoStep() {
        let m = model()
        let original = m.document
        m.select(nodes: [node(m, "input.uv").id, node(m, "input.time").id], mode: .replace)
        m.deleteSelection()
        #expect(m.document.root.nodes.count == 9)
        #expect(m.selection.isEmpty)
        m.undo()
        #expect(m.document == original)
    }

    @Test func deleteSelectionRemovesASelectedWireInstead() {
        let m = model()
        let out = node(m, "output.fragment").id
        m.select(node(m, "input.uv").id)
        m.selectedWire = SocketRef(out, "color")
        m.deleteSelection()
        #expect(m.document.root.source(feeding: SocketRef(out, "color")) == nil)
        #expect(m.document.root.nodes.count == 11)
        #expect(m.selectedWire == nil)
    }

    @Test func nudgeMovesEverySelectedNodeInOneStep() {
        let m = model()
        let a = node(m, "input.uv").id, b = node(m, "input.time").id
        let pa = m.document.root.nodes[a]!.position, pb = m.document.root.nodes[b]!.position
        m.select(nodes: [a, b], mode: .replace)
        m.nudgeSelection(by: CGSize(width: 10, height: -10))
        #expect(m.document.root.nodes[a]!.position == CGPoint(x: pa.x + 10, y: pa.y - 10))
        #expect(m.document.root.nodes[b]!.position == CGPoint(x: pb.x + 10, y: pb.y - 10))
        m.undo()
        #expect(m.document.root.nodes[a]!.position == pa)
        #expect(!m.canUndo)
    }

    @Test func boundsAndHitTesting() {
        let m = model()
        let uv = node(m, "input.uv").id
        #expect(m.frame(of: uv)?.origin == .zero)
        #expect(m.node(at: CGPoint(x: 20, y: 20)) == uv)
        #expect(m.node(at: CGPoint(x: -5, y: -5)) == nil)
        m.select(uv)
        #expect(m.selectionBounds == m.frame(of: uv))
        #expect(m.contentBounds!.maxX == 1290)
    }

    @Test func addNodePlacesSelectsAndUndoes() {
        let m = model()
        let original = m.document
        let id = m.addNode(defID: "noise.value", at: CGPoint(x: 300, y: 300))!
        #expect(m.document.root.nodes[id]?.position == CGPoint(x: 300, y: 300))
        #expect(m.selection == [id])
        #expect(m.addNode(defID: "nope", at: .zero) == nil)
        m.undo()
        #expect(m.document == original)
    }

    @Test func canvasRequestsAreObservableAndOneShot() {
        let m = model()
        #expect(m.canvasRequest == nil)
        m.requestCanvas(.fitSelection)
        #expect(m.canvasRequest == .fitSelection)
        m.canvasRequest = nil
        #expect(m.canvasRequest == nil)
    }

    @Test func connectIfCompatibleChecksTypesAndNodes() {
        let m = model()
        let uv = node(m, "input.uv"), comb = node(m, "vector.combine")
        #expect(m.connectIfCompatible(SocketRef(uv.id, "uv"), to: SocketRef(comb.id, "z")))      // float2 → float (average)
        #expect(m.document.root.source(feeding: SocketRef(comb.id, "z")) == SocketRef(uv.id, "uv"))
        let bogus = NodeInstance(kind: .builtin("input.uv"))
        #expect(m.connectIfCompatible(SocketRef(bogus.id, "uv"), to: SocketRef(comb.id, "x")) == false)  // unknown node
    }
}
