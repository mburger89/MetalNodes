import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// The document window's `UndoManager` is handed to the model (spec §21.1): edits land on the
/// window's stack so the File menu's dirty state and the standard Undo item stay in step.
@MainActor
@Suite struct EditorUndoInjectionTests {
    private func model(undoManager: UndoManager? = nil) -> EditorModel {
        let m = EditorModel(document: .starter(), compiler: RecordingCompiler(), undoManager: undoManager)
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func uv(_ m: EditorModel) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
    }

    @Test func editsRegisterOnTheInjectedManager() {
        let external = UndoManager()
        external.groupsByEvent = false
        let m = model(undoManager: external)
        let original = m.document
        let node = uv(m)

        m.apply(.moveNodes([node.id: CGPoint(x: 99, y: 99)]))

        #expect(external.canUndo)
        #expect(external.undoActionName == "Move")
        external.undo()
        #expect(m.document == original)
        #expect(external.canRedo)
        external.redo()
        #expect(m.document.root.nodes[node.id]?.position == CGPoint(x: 99, y: 99))
    }

    @Test func theModelUsesTheInjectedManagerAsItsOwn() {
        let external = UndoManager()
        let m = model(undoManager: external)
        #expect(m.undoManager === external)
    }

    @Test func withoutInjectionThePrivateManagerStillWorks() {
        let m = model()
        let original = m.document
        let node = uv(m)
        m.apply(.moveNodes([node.id: CGPoint(x: 7, y: 7)]))
        #expect(m.canUndo)
        #expect(m.undoManager.undoActionName == "Move")
        m.undo()
        #expect(m.document == original)
        #expect(m.canRedo)
    }

    @Test func adoptTakesTheWindowManagerWhileTheStackIsEmpty() {
        let m = model()
        let window = UndoManager()
        m.adoptUndoManager(window)
        #expect(m.undoManager === window)

        let node = uv(m)
        m.apply(.moveNodes([node.id: CGPoint(x: 5, y: 5)]))
        #expect(window.canUndo)
    }

    @Test func adoptRefusesOnceSomethingIsOnTheStack() {
        let m = model()
        let node = uv(m)
        m.apply(.moveNodes([node.id: CGPoint(x: 5, y: 5)]))
        let own = m.undoManager

        m.adoptUndoManager(UndoManager())

        #expect(m.undoManager === own)
        #expect(m.canUndo)
    }

    @Test func packageCarriesTheDocumentViewStateAndTextures() {
        let m = model()
        let asset = AssetID()
        m.textures = [asset: Data([1, 2, 3])]
        m.viewState.selection = [uv(m).id]

        let package = m.package
        #expect(package.document == m.document)
        #expect(package.viewState == m.viewState)
        #expect(package.textures == [asset: Data([1, 2, 3])])
    }

    /// The document host mirrors `textures` into the file wrapper with `onChange`, which only
    /// fires while the property is observation-tracked — a property observer on it must not
    /// silently opt it out of `@Observable`.
    @Test func texturesStayObservable() {
        nonisolated final class Box: @unchecked Sendable { var fired = false }
        let box = Box()
        let m = model()
        withObservationTracking { _ = m.textures } onChange: { box.fired = true }
        m.textures = [AssetID(): Data([9])]
        #expect(box.fired)
    }

    @Test func missingTexturesBecomeWarningsAfterCompiling() async {
        var doc = ShaderDocument.starter()
        let asset = AssetID()
        doc.settings.assets[asset] = AssetInfo(name: "clouds.png", pixelSize: CGSize(width: 8, height: 8), fileExtension: "png")
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(asset)])
        doc.root.nodes[sample.id] = sample
        let out = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        doc.root.connect(SocketRef(sample.id, "color"), to: SocketRef(out.id, "color"))

        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        m.missingTextures = [asset]
        m.start()
        await m.awaitIdle()

        #expect(m.diagnostics.map(\.message) == ["Texture “clouds.png” is missing"])
        #expect(m.diagnostics.map(\.severity) == [Diagnostic.Severity.warning])
    }
}
