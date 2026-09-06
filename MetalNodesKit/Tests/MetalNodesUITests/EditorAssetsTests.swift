import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Image import, the asset manifest and the missing-texture warning (spec §21.2).
@MainActor
@Suite struct EditorAssetsTests {
    /// A 2×2 PNG (magenta/black checker), written by hand so the tests never touch the file system
    /// for their pixels. `Data(base64Encoded:)` of a literal *is* the byte literal.
    static let png2x2 = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42mP4z/D/PwMDAwiDWP//AwBDzgf5hVEFWgAAAABJRU5ErkJggg==
        """)!
    /// A 4×1 PNG, so a re-import can be told apart from the 2×2 one by its pixel size alone.
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

    // MARK: Import

    @Test func importAddsAManifestEntryAndTheBytes() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.PNG"))
        let info = try #require(m.document.settings.assets[id])
        #expect(info.name == "Leaf.PNG")
        #expect(info.pixelSize == CGSize(width: 2, height: 2))
        #expect(info.fileExtension == "png")          // taken from the name, lowercased
        #expect(m.textures[id] == Self.png2x2)        // stored verbatim, never re-encoded
    }

    @Test func importFallsBackToPNGWhenTheNameHasNoExtension() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf"))
        #expect(m.document.settings.assets[id]?.fileExtension == "png")
    }

    @Test func importRefusesDataThatIsNotAnImage() {
        let m = model()
        #expect(m.importImage(data: Data("not an image".utf8), name: "notes.png") == nil)
        #expect(m.notice == "That file is not an image")
        #expect(m.document.settings.assets.isEmpty)
        #expect(m.textures.isEmpty)
    }

    @Test func importBumpsTheTexturesVersion() throws {
        let m = model()
        let before = m.texturesVersion
        _ = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        #expect(m.texturesVersion == before + 1)
    }

    // MARK: Add Texture

    @Test func addTextureNodeIsOneUndoStep() throws {
        let m = model()
        let node = try #require(m.addTextureNode(imageData: Self.png2x2, name: "Leaf.png", at: CGPoint(x: 40, y: 60)))
        let id = try #require(asset(m, of: node))
        #expect(m.document.root.nodes[node]?.kind == .builtin("texture.sample"))
        #expect(m.document.root.nodes[node]?.position == CGPoint(x: 40, y: 60))
        #expect(m.document.settings.assets[id]?.name == "Leaf.png")
        #expect(m.undoManager.undoActionName == "Add Texture")

        m.undo()
        #expect(m.document.root.nodes[node] == nil)
        #expect(m.document.settings.assets.isEmpty)
        #expect(m.textures[id] == Self.png2x2)        // bytes stay; the manifest is what undo tracks
        #expect(!m.canUndo)                           // exactly one step for import + node + assignment
    }

    @Test func addTextureNodeRefusesDataThatIsNotAnImage() {
        let m = model()
        let before = m.document
        #expect(m.addTextureNode(imageData: Data("not an image".utf8), name: "notes.png", at: .zero) == nil)
        #expect(m.document == before)
        #expect(!m.canUndo)
    }

    @Test func addTextureNodeReadsAnImageFile() throws {
        let m = model()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditorAssetsTests-\(UUID().uuidString)")
            .appendingPathExtension("png")
        try Self.png4x1.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let node = try #require(m.addTextureNode(contentsOf: url, at: .zero))
        let id = try #require(asset(m, of: node))
        #expect(m.document.settings.assets[id]?.name == url.lastPathComponent)
        #expect(m.document.settings.assets[id]?.pixelSize == CGSize(width: 4, height: 1))
    }

    // MARK: References and removal

    @Test func removeAssetRefusesWhileReferencedAndSucceedsAfterTheNodeGoes() throws {
        let m = model()
        let node = try #require(m.addTextureNode(imageData: Self.png2x2, name: "Leaf.png", at: .zero))
        let id = try #require(asset(m, of: node))
        #expect(m.isAssetReferenced(id))
        #expect(!m.removeAsset(id))
        #expect(m.notice == "That image is still in use")
        #expect(m.document.settings.assets[id] != nil)

        m.apply(.removeNodes([node]))
        #expect(!m.isAssetReferenced(id))
        #expect(m.removeAsset(id))
        #expect(m.document.settings.assets.isEmpty)
        #expect(m.textures[id] == nil)
        #expect(m.undoManager.undoActionName == "Remove Asset")
    }

    @Test func removeAssetUndoesBackIntoTheManifest() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        #expect(m.removeAsset(id))
        m.undo()
        #expect(m.document.settings.assets[id]?.name == "Leaf.png")
    }

    @Test func referenceInsideADefinitionCounts() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        #expect(!m.isAssetReferenced(id))

        var def = GroupDefinition.make(name: "Tex")
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(id)])
        def.graph.nodes[sample.id] = sample
        var doc = m.document
        doc.definitions[def.id] = def
        m.apply(.restore(doc))

        #expect(m.isAssetReferenced(id))
        #expect(!m.removeAsset(id))
        #expect(m.document.settings.assets[id] != nil)
    }

    @Test func assetListIsSortedByName() throws {
        let m = model()
        _ = try #require(m.importImage(data: Self.png2x2, name: "zebra.png"))
        _ = try #require(m.importImage(data: Self.png4x1, name: "Apple.png"))
        #expect(m.assetList.map(\.info.name) == ["Apple.png", "zebra.png"])
    }

    // MARK: Missing textures

    @Test func theMissingWarningClearsWhenTheBytesComeBack() async throws {
        let m = model()
        let node = try #require(m.addTextureNode(imageData: Self.png2x2, name: "Leaf.png", at: .zero))
        let id = try #require(asset(m, of: node))
        let out = try #require(m.document.root.nodes.values.first { $0.kind == .builtin("output.fragment") })
        m.apply(.connect(from: SocketRef(node, "color"), to: SocketRef(out.id, "color")))

        // The bytes went missing the way an opened package reports them (spec §21.2).
        m.textures[id] = nil
        m.missingTextures = [id]
        m.start()
        await m.awaitIdle()
        #expect(m.diagnostics.map(\.message) == ["Texture “Leaf.png” is missing"])

        #expect(m.replaceAssetBytes(id, data: Self.png4x1))
        await m.awaitIdle()
        #expect(m.missingTextures.isEmpty)
        #expect(m.diagnostics.isEmpty)
        #expect(m.textures[id] == Self.png4x1)
        #expect(m.document.settings.assets[id]?.pixelSize == CGSize(width: 4, height: 1))
        #expect(m.document.settings.assets[id]?.name == "Leaf.png")     // the manifest name is kept
    }

    @Test func replaceRefusesDataThatIsNotAnImage() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        #expect(!m.replaceAssetBytes(id, data: Data("not an image".utf8)))
        #expect(m.notice == "That file is not an image")
        #expect(m.textures[id] == Self.png2x2)
        #expect(m.document.settings.assets[id]?.pixelSize == CGSize(width: 2, height: 2))
    }

    @Test func replaceRefusesAnAssetTheManifestDoesNotHold() {
        let m = model()
        #expect(!m.replaceAssetBytes(AssetID(), data: Self.png2x2))
        #expect(m.textures.isEmpty)
    }

    // MARK: Assignment

    @Test func assignAssetSetsTheParam() throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        let node = try #require(m.addNode(defID: "texture.sample", at: .zero))
        m.assignAsset(id, to: node)
        #expect(asset(m, of: node) == id)
        m.assignAsset(nil, to: node)
        #expect(m.document.root.nodes[node]?.params["asset"] == .asset(nil))
    }
}
