import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

/// The platform seams (spec §22.4) driven by the in-memory doubles: what the image well's
/// "Choose…", the Assets list's "Relink…" and File ▸ Export Shader… do, with no panel and no
/// picker on screen.
@MainActor
@Suite struct EditorServicesTests {
    /// The same 2×2 PNG `EditorAssetsTests` uses — a byte literal, so no test needs the file system.
    static let png2x2 = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42mP4z/D/PwMDAwiDWP//AwBDzgf5hVEFWgAAAABJRU5ErkJggg==
        """)!
    /// A 4×1 PNG, so a relink can be told apart from the 2×2 bytes by its pixel size alone.
    static let png4x1 = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAYAAAD5PA/NAAAAEklEQVR42mP4z8DwHwwZ/oMBAEXLCff38S+qAAAAAElFTkSuQmCC
        """)!

    private func model(_ document: ShaderDocument = .starter()) -> EditorModel {
        let m = EditorModel(document: document, compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    private func asset(_ m: EditorModel, of node: NodeID) -> AssetID? {
        guard let v = m.document.root.nodes[node]?.params["asset"], case .asset(let a) = v else { return nil }
        return a
    }

    // MARK: Choose Image

    @Test func chooseImageImportsAndAssignsAsOneUndoStep() async throws {
        let m = model()
        let node = try #require(m.addNode(defID: "texture.sample", at: CGPoint(x: 40, y: 60)))
        let chooser = MemoryImageChooser(next: PickedImage(data: Self.png2x2, name: "Leaf.png"))
        await m.chooseImage(for: node, param: "asset", from: .photos, using: chooser)

        #expect(chooser.requests == [.photos])
        let id = try #require(asset(m, of: node))
        #expect(m.document.settings.assets[id]?.name == "Leaf.png")
        #expect(m.textures[id] == Self.png2x2)
        #expect(m.undoManager.undoActionName == "Choose Image")
        // One step: undoing it takes the manifest entry *and* the assignment back together.
        m.undo()
        #expect(asset(m, of: node) == nil)
        #expect(m.document.settings.assets.isEmpty)
        await m.awaitIdle()
    }

    @Test func aCancelledChooserChangesNothing() async throws {
        let m = model()
        let node = try #require(m.addNode(defID: "texture.sample", at: .zero))
        let before = m.document
        let version = m.undoStackVersion
        let chooser = MemoryImageChooser()                     // `next` is nil: the user cancelled
        await m.chooseImage(for: node, param: "asset", from: .files, using: chooser)

        #expect(chooser.requests == [.files])
        #expect(m.document == before)
        #expect(m.textures.isEmpty)
        #expect(m.undoStackVersion == version)                 // no transaction was ever opened
        await m.awaitIdle()
    }

    // MARK: Relink

    @Test func relinkAssetReplacesTheBytes() async throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        m.missingTextures = [id]
        let chooser = MemoryImageChooser(next: PickedImage(data: Self.png4x1, name: "Leaf.png"))
        await m.relinkAsset(id, from: .files, using: chooser)

        #expect(chooser.requests == [.files])
        #expect(m.textures[id] == Self.png4x1)
        #expect(m.document.settings.assets[id]?.pixelSize == CGSize(width: 4, height: 1))
        #expect(m.missingTextures.isEmpty)
        await m.awaitIdle()
    }

    @Test func aCancelledRelinkLeavesTheBytesAlone() async throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        m.missingTextures = [id]
        await m.relinkAsset(id, from: .photos, using: MemoryImageChooser())

        #expect(m.textures[id] == Self.png2x2)
        #expect(m.missingTextures == [id])
        await m.awaitIdle()
    }

    // MARK: Export

    @Test func exportShaderPassesTheFilesAndReturnsTheOutcome() async throws {
        let m = model()
        let exporter = MemoryExporter()
        exporter.outcome = .saved
        #expect(await m.exportShader(using: exporter) == .saved)

        let expected = try m.exportFiles()
        #expect(exporter.exported.count == 1)
        let call = try #require(exporter.exported.first)
        #expect(call.name == "metalNodesShader")
        #expect(call.files == expected)
        #expect(call.files.map(\.name) == ["metalNodesShader.metal"])
        await m.awaitIdle()
    }

    @Test func exportShaderForwardsACancellation() async {
        let m = model()
        let exporter = MemoryExporter()
        exporter.outcome = .cancelled
        #expect(await m.exportShader(using: exporter) == .cancelled)
        await m.awaitIdle()
    }

    @Test func anInvalidGraphFailsBeforeTheExporterIsAsked() async throws {
        let m = model()
        let out = try #require(m.document.root.nodes.values.first { $0.kind == .builtin("output.fragment") })
        m.apply(.removeNodes([out.id]))
        let exporter = MemoryExporter()

        #expect(await m.exportShader(using: exporter) == .failed("The graph has errors; fix them before exporting."))
        #expect(exporter.exported.isEmpty)
        await m.awaitIdle()
    }
}
