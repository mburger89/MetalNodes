import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorClipboardTests {
    private func model(_ pb: any Pasteboarding = MemoryPasteboard()) -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler(), pasteboard: pb)
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func copyWritesTheGraphTypeAndPasteInsertsFreshNodes() throws {
        let pb = MemoryPasteboard()
        let m = model(pb)
        let uv = node(m, "input.uv"), sep = node(m, "vector.separate")     // uv → sep.v is an internal edge
        #expect(!m.canCopy && !m.canPaste)
        m.select(nodes: [uv.id, sep.id], mode: .replace)
        #expect(m.canCopy)
        m.copySelection()
        #expect(m.canPaste)
        let data = try #require(pb.read(type: EditorModel.pasteboardType))
        let clip = try JSONDecoder().decode(GraphClipboard.self, from: data)
        #expect(clip.nodes.count == 2 && clip.edges.count == 1)

        let before = m.document.root.nodes.count
        let pasted = m.paste(at: CGPoint(x: 2000, y: 2000))
        #expect(pasted.count == 2)
        #expect(m.document.root.nodes.count == before + 2)
        #expect(m.selection == pasted)
        #expect(pasted.isDisjoint(with: [uv.id, sep.id]))
        let newSep = pasted.first { m.document.root.nodes[$0]?.kind == .builtin("vector.separate") }!
        #expect(m.document.root.source(feeding: SocketRef(newSep, "v"))?.node != uv.id)   // wired to the *copied* uv
        #expect(m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") && $0.id != uv.id }?.position == CGPoint(x: 2000, y: 2000))
    }

    @Test func pasteIsOneUndoStep() {
        let m = model()
        let original = m.document
        m.select(node(m, "input.uv").id)
        m.copySelection()
        m.paste()
        #expect(m.document.root.nodes.count == 12)
        m.undo()
        #expect(m.document == original)
    }

    @Test func menuPasteOffsetsFromTheSourceOrigin() {
        let m = model()
        let time = node(m, "input.time")                                   // at (0, 160)
        m.select(time.id)
        m.copySelection()
        let pasted = m.paste()
        #expect(m.document.root.nodes[pasted.first!]?.position == CGPoint(x: 24, y: 184))
    }

    @Test func cutCopiesThenDeletes() {
        let m = model()
        let uv = node(m, "input.uv")
        m.select(uv.id)
        m.cutSelection()
        #expect(m.document.root.nodes[uv.id] == nil)
        #expect(m.canPaste)
        let pasted = m.paste(at: .zero)
        #expect(pasted.count == 1)
    }

    @Test func duplicateNeverTouchesThePasteboardAndUndoesAsOne() {
        let pb = MemoryPasteboard()
        let m = model(pb)
        let original = m.document
        let uv = node(m, "input.uv")
        m.select(uv.id)
        let dup = m.duplicateSelection()
        #expect(dup.count == 1)
        #expect(pb.read(type: EditorModel.pasteboardType) == nil)
        #expect(m.document.root.nodes[dup.first!]?.position == CGPoint(x: 24, y: 24))
        #expect(m.selection == dup)
        m.undo()
        #expect(m.document == original)
    }

    @Test func crossDocumentPasteThroughASharedPasteboard() {
        let pb = MemoryPasteboard()
        let a = model(pb), b = model(pb)
        a.select(node(a, "noise.value").id)
        a.copySelection()
        let pasted = b.paste(at: .zero)
        #expect(pasted.count == 1)
        #expect(b.document.root.nodes.count == 12)
    }

    @Test func garbageOnThePasteboardIsANoOp() {
        let pb = MemoryPasteboard()
        pb.write(Data("not json".utf8), type: EditorModel.pasteboardType)
        let m = model(pb)
        #expect(m.paste().isEmpty)
        #expect(m.document.root.nodes.count == 11)
        #expect(!m.canUndo)
    }
}
