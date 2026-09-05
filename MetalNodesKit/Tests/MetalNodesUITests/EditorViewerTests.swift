import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorViewerTests {
    private func model() -> (EditorModel, RecordingCompiler) {
        let c = RecordingCompiler()
        let m = EditorModel(document: .sample(), compiler: c)
        m.debounceInterval = .milliseconds(5)
        return (m, c)
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance { m.document.root.nodes.values.first { $0.kind == .builtin(defID) }! }

    @Test func settingTheViewerSchedulesOneCompileAndIsNotUndoable() async {
        let (m, c) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out"))
        await m.awaitIdle()
        #expect(m.viewer == SocketRef(noise.id, "out"))
        #expect(await c.generations.count == 2)
        #expect(!m.canUndo)
        #expect(m.generatedSource.contains("u.viewerMin"))
        #expect(m.viewedType == .float)
    }

    @Test func toggleClearsWhenAlreadyViewed() async {
        let (m, _) = model()
        let noise = node(m, "noise.value")
        m.toggleViewer(SocketRef(noise.id, "out"))
        m.toggleViewer(SocketRef(noise.id, "out"))
        #expect(m.viewer == nil)
    }

    @Test func toggleOnSelectionUsesTheFirstOutput() {
        let (m, _) = model()
        let sep = node(m, "vector.separate")
        m.select(sep.id)
        m.toggleViewerOnSelection()
        #expect(m.viewer == SocketRef(sep.id, "x"))
        m.select(nodes: [sep.id, node(m, "input.uv").id], mode: .replace)
        m.toggleViewerOnSelection()                    // two selected: no change
        #expect(m.viewer == SocketRef(sep.id, "x"))
    }

    @Test func deletingTheViewedNodeClearsTheViewer() async {
        let (m, c) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out")); await m.awaitIdle()
        m.apply(.removeNodes([noise.id])); await m.awaitIdle()
        #expect(m.viewer == nil)
        #expect(!m.generatedSource.contains("u.viewerMin"))
        #expect(await c.generations.count == 3)
    }

    @Test func undoRestoresTheNodeButNotTheViewer() async {
        let (m, _) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out"))
        m.apply(.removeNodes([noise.id]))
        m.undo(); await m.awaitIdle()
        #expect(m.document.root.nodes[noise.id] != nil)
        #expect(m.viewer == nil)                       // view state is never undone (spec §5)
    }

    @Test func socketLabelUsesCustomTitleThenDefinitionTitle() {
        let (m, _) = model()
        let noise = node(m, "noise.value")
        #expect(m.socketLabel(SocketRef(noise.id, "out")) == "Value Noise.out")
        m.apply(.setTitle(noise.id, "Grain"))
        #expect(m.socketLabel(SocketRef(noise.id, "out")) == "Grain.out")
    }

    @Test func errorNodesComeFromErrorDiagnosticsOnly() async {
        let (m, _) = model()
        m.start(); await m.awaitIdle()
        #expect(m.errorNodes.isEmpty)
        let mul = node(m, "math.math")
        m.apply(.connect(from: SocketRef(mul.id, "out"), to: SocketRef(mul.id, "b")))   // a cycle
        await m.awaitIdle()
        #expect(m.errorNodes.contains(mul.id))
    }
}
