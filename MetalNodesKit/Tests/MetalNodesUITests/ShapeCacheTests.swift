import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

/// `EditorModel.shapes` (spec §21.8): one `NodeShape` per node of the active graph, rebuilt only
/// when the document changes or the editor moves to another graph — every canvas layout pass reads
/// it, so recomputing it per call would walk the document once per node per frame.
@MainActor
@Suite struct ShapeCacheTests {
    private func model(_ document: ShaderDocument = .sample()) -> EditorModel {
        let m = EditorModel(document: document, compiler: RecordingCompiler(), pasteboard: MemoryPasteboard())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    @Test func repeatedReadsReuseTheCache() {
        let m = model()
        let first = m.shapes
        #expect(first.count == m.document.root.nodes.count)
        let rebuilds = m.shapeCacheRebuilds
        #expect(m.shapes == first)
        #expect(m.shapeCacheRebuilds == rebuilds)          // the second read did not recompute
        // The public accessors read the same cache.
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(m.shape(of: uv) == first[uv.id])
        #expect(m.shape(of: uv.id) == first[uv.id])
        #expect(m.shapeCacheRebuilds == rebuilds)
    }

    @Test func anEditRebuildsTheCache() {
        let m = model()
        let before = m.shapes
        let rebuilds = m.shapeCacheRebuilds
        let added = NodeInstance(kind: .builtin("input.uv"), position: .zero)
        m.apply(.addNode(added))
        let after = m.shapes
        #expect(after != before)
        #expect(after.count == before.count + 1)
        #expect(after[added.id] == NodeRegistry.builtin["input.uv"].map(NodeShape.init(def:)))
        #expect(m.shapeCacheRebuilds == rebuilds + 1)
    }

    @Test func divingInSwitchesToTheDefinitionAndItsPseudoNodes() {
        let m = model()
        let mul = m.document.root.nodes.values.first {
            $0.kind == .builtin("math.math") && $0.params["op"] == .enumCase("multiply")
        }!.id
        m.select(nodes: [mul], mode: .replace)
        #expect(m.groupSelection() != nil)
        let instance = m.selection.first!
        #expect(!m.shapes.values.contains { $0.isPseudo })          // the root has no pseudo-nodes

        m.diveIn(instance)
        let inner = m.shapes
        #expect(inner.count == m.graph.nodes.count)
        #expect(inner.values.filter(\.isPseudo).map(\.title).sorted() == ["Group Input", "Group Output"])
        // Diving is view state, not a document change: the cache still had to follow it.
        let rebuilds = m.shapeCacheRebuilds
        #expect(m.shapes == inner)
        #expect(m.shapeCacheRebuilds == rebuilds)

        // A node of another graph is outside the cache and still resolves through the document.
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(inner[uv.id] == nil)
        #expect(m.shape(of: uv.id)?.title == NodeRegistry.builtin["input.uv"]?.title)
    }

    @Test func reloadingThePackageRebuildsTheCache() {
        let m = model()
        let before = m.shapes
        m.reload(package: ShaderPackage(document: ShaderDocument(), viewState: EditorViewState()))
        #expect(m.shapes.isEmpty)
        #expect(m.shapes != before)
    }
}
