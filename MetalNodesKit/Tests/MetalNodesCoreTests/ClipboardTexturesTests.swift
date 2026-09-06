import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// Spec §13, §21.2: the clipboard carries the manifest entry (and bytes, when available) for every
/// `.asset` param a copied node or a carried definition references.
@Suite struct ClipboardTexturesTests {
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    @Test func extractCollectsAnAssetReferencedByACopiedNode() {
        var doc = ShaderDocument()
        let info = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        doc.settings.assets[aid(1)] = info
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        doc.root.nodes[sample.id] = sample
        let bytes = Data([0xAA, 0xBB])

        let clip = GraphClipboard.extract([sample.id], from: doc.root, document: doc, textures: [aid(1): bytes])
        #expect(clip.assetInfos == [aid(1): info])
        #expect(clip.textures == [aid(1): bytes])
    }

    @Test func extractCollectsAnAssetReferencedInsideACarriedDefinition() {
        var doc = ShaderDocument()
        let info = AssetInfo(name: "wood.png", pixelSize: CGSize(width: 32, height: 32), fileExtension: "png")
        doc.settings.assets[aid(2)] = info
        var def = GroupDefinition.make(name: "Sampler")
        def.outputs = [SocketDecl(name: "color", type: .concrete(.float4))]
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        def.graph.nodes[sample.id] = sample
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id))
        doc.root.nodes[inst.id] = inst
        let bytes = Data([0x01, 0x02, 0x03])

        let clip = GraphClipboard.extract([inst.id], from: doc.root, document: doc, textures: [aid(2): bytes])
        #expect(clip.definitions.map(\.id) == [def.id])
        #expect(clip.assetInfos == [aid(2): info])
        #expect(clip.textures == [aid(2): bytes])
    }

    /// An asset the source document knows about but has no bytes for still carries its manifest
    /// entry — only the bytes are conditional on `textures` having them.
    @Test func extractCarriesTheManifestEntryEvenWithoutBytes() {
        var doc = ShaderDocument()
        let info = AssetInfo(name: "missing.png", pixelSize: CGSize(width: 8, height: 8), fileExtension: "png")
        doc.settings.assets[aid(3)] = info
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(3))])
        doc.root.nodes[sample.id] = sample

        let clip = GraphClipboard.extract([sample.id], from: doc.root, document: doc)
        #expect(clip.assetInfos == [aid(3): info])
        #expect(clip.textures.isEmpty)
    }

    /// A copied node with an unassigned (`.asset(nil)`) or unreferenced asset contributes nothing.
    @Test func unassignedAssetIsNotCollected() {
        var doc = ShaderDocument()
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(nil)])
        doc.root.nodes[sample.id] = sample
        let clip = GraphClipboard.extract([sample.id], from: doc.root, document: doc)
        #expect(clip.assetInfos.isEmpty)
        #expect(clip.textures.isEmpty)
    }

    @Test func jsonRoundTripKeepsBytesAndInfo() throws {
        var clip = GraphClipboard(nodes: [], edges: [])
        let info = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        clip.assetInfos[aid(4)] = info
        clip.textures[aid(4)] = Data([0xDE, 0xAD, 0xBE, 0xEF])

        let data = try JSONEncoder().encode(clip)
        let decoded = try JSONDecoder().decode(GraphClipboard.self, from: data)
        #expect(decoded.assetInfos == [aid(4): info])
        #expect(decoded.textures == [aid(4): Data([0xDE, 0xAD, 0xBE, 0xEF])])
    }

    /// A clipboard payload written before `assetInfos`/`textures` existed still decodes, as empty.
    @Test func decodingAnOlderPayloadWithoutAssetKeysDefaultsToEmpty() throws {
        let json = #"{"nodes":[],"edges":[]}"#
        let decoded = try JSONDecoder().decode(GraphClipboard.self, from: Data(json.utf8))
        #expect(decoded.assetInfos.isEmpty)
        #expect(decoded.textures.isEmpty)
    }
}
