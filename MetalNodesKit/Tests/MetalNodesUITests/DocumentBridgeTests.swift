import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

@MainActor
@Suite struct DocumentBridgeTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .starter(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    @Test func packageCarriesTheMissingSet() {
        let m = model()
        let a = AssetID()
        m.missingTextures = [a]
        let bridge = DocumentBridge(model: m)
        #expect(bridge.package.missingTextures == [a])
        #expect(bridge.package.document == m.document)
    }

    @Test func mirrorWritesOnlyWhatDiffers() {
        let m = model()
        let bridge = DocumentBridge(model: m)
        var file = bridge.package
        #expect(bridge.mirror(into: &file).isEmpty)          // already equal: nothing written
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        m.apply(.moveNodes([uv.id: CGPoint(x: 9, y: 9)]))
        #expect(bridge.mirror(into: &file) == [.document])
        #expect(file.document == m.document)
        #expect(file.viewState == m.viewState)
    }

    @Test func applyIsANoOpForThePackageTheModelAlreadyHolds() {
        let m = model()
        let bridge = DocumentBridge(model: m)
        let before = m.undoStackVersion
        #expect(bridge.apply(bridge.package) == false)
        #expect(m.undoStackVersion == before)
    }

    @Test func applyReloadsAnExternalChangeAndDropsUndo() async {
        let m = model()
        let bridge = DocumentBridge(model: m)
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        m.apply(.moveNodes([uv.id: CGPoint(x: 9, y: 9)]))
        #expect(m.canUndo)
        var incoming = bridge.package
        incoming.document.root.nodes[uv.id]?.position = CGPoint(x: 1, y: 2)
        #expect(bridge.apply(incoming) == true)
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 1, y: 2))
        #expect(!m.canUndo)
        await m.awaitIdle()
    }
}
