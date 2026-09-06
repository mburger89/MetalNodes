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

    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "30000000-0000-0000-0000-%012d", n))!) }

    /// A minimal document holding one `texture.sample` node that references `assetID`.
    private func docWithTexture(_ assetID: AssetID, info: AssetInfo) -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.assets[assetID] = info
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(assetID)])
        d.root.nodes[sample.id] = sample
        return d
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
        let newUV = try #require(pasted.first { m.document.root.nodes[$0]?.kind == .builtin("input.uv") })
        let src = try #require(m.document.root.source(feeding: SocketRef(newSep, "v")))
        #expect(src.node == newUV)   // wired to the *copied* uv, not the original
        #expect(m.document.root.nodes[newUV]?.position == CGPoint(x: 2000, y: 2000))
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

    @Test func clipboardDataIsWhatCopyWritesAndNilWithoutASelection() throws {
        let pb = MemoryPasteboard()
        let m = model(pb)
        #expect(m.clipboardData() == nil)
        m.selectAll()
        let direct = try JSONDecoder().decode(GraphClipboard.self, from: try #require(m.clipboardData()))
        m.copySelection()
        let written = try JSONDecoder().decode(GraphClipboard.self, from: try #require(pb.read(type: EditorModel.pasteboardType)))
        #expect(Set(written.nodes.map(\.id)) == Set(direct.nodes.map(\.id)))
        #expect(written.nodes.count == m.document.root.nodes.count)
    }

    /// Spec §13, §21.2: pasting a node that samples an asset the destination doesn't know about
    /// adds the manifest entry and the bytes, and the pasted node still points at the same id.
    @Test func pastingAnAssetTheDestinationLacksAddsManifestAndBytes() {
        let pb = MemoryPasteboard()
        let id = aid(1)
        let info = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let bytes = Data([0xAA, 0xBB, 0xCC])
        let a = EditorModel(document: docWithTexture(id, info: info), textures: [id: bytes],
                             compiler: RecordingCompiler(), pasteboard: pb)
        a.select(node(a, "texture.sample").id)
        a.copySelection()

        let b = EditorModel(document: ShaderDocument(), compiler: RecordingCompiler(), pasteboard: pb)
        #expect(b.document.settings.assets[id] == nil)
        let pasted = b.paste()
        #expect(pasted.count == 1)
        #expect(b.document.settings.assets[id] == info)
        #expect(b.textures[id] == bytes)
        #expect(b.document.root.nodes[pasted.first!]?.params["asset"] == .asset(id))
    }

    /// An asset id the destination already has keeps its own bytes and manifest entry — the
    /// source's never overwrite them.
    @Test func pastingAnAssetTheDestinationAlreadyHasLeavesItUntouched() {
        let pb = MemoryPasteboard()
        let id = aid(2)
        let sourceInfo = AssetInfo(name: "source.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let sourceBytes = Data([0x01])
        let a = EditorModel(document: docWithTexture(id, info: sourceInfo), textures: [id: sourceBytes],
                             compiler: RecordingCompiler(), pasteboard: pb)
        a.select(node(a, "texture.sample").id)
        a.copySelection()

        let destInfo = AssetInfo(name: "dest.png", pixelSize: CGSize(width: 32, height: 32), fileExtension: "png")
        let destBytes = Data([0x02])
        var destDoc = ShaderDocument()
        destDoc.settings.assets[id] = destInfo
        let b = EditorModel(document: destDoc, textures: [id: destBytes], compiler: RecordingCompiler(), pasteboard: pb)

        let pasted = b.paste()
        #expect(pasted.count == 1)
        #expect(b.document.settings.assets[id] == destInfo)
        #expect(b.textures[id] == destBytes)
        #expect(b.document.root.nodes[pasted.first!]?.params["asset"] == .asset(id))
    }
}
