import Foundation
import CoreGraphics
import MetalNodesCore

extension EditorModel {
    public var canCopy: Bool { !selection.isEmpty }
    public var canPaste: Bool { pasteboard.read(type: Self.pasteboardType) != nil }

    public func copySelection() {
        guard canCopy else { return }
        let clip = GraphClipboard.extract(selection, from: document.root)
        if let data = try? JSONEncoder().encode(clip) {
            pasteboard.write(data, type: Self.pasteboardType)
        }
    }

    public func cutSelection() {
        guard canCopy else { return }
        copySelection()
        deleteSelection()
    }

    /// Pastes as one `Paste` step at `point` (bounding-box origin), or +24,+24 from where it was copied.
    @discardableResult
    public func paste(at point: CGPoint? = nil) -> Set<NodeID> {
        guard let data = pasteboard.read(type: Self.pasteboardType),
              let clip = try? JSONDecoder().decode(GraphClipboard.self, from: data),
              clip.formatVersion <= GraphClipboard.currentFormatVersion, !clip.nodes.isEmpty else { return [] }
        let origin = point ?? CGPoint(x: clip.sourceOrigin.x + 24, y: clip.sourceOrigin.y + 24)
        return insert(clip, at: origin, undoName: "Paste")
    }

    /// Copy + paste without the pasteboard; one `Duplicate` step.
    @discardableResult
    public func duplicateSelection(offset: CGSize = CGSize(width: 24, height: 24)) -> Set<NodeID> {
        guard canCopy else { return [] }
        let clip = GraphClipboard.extract(selection, from: document.root)
        let origin = CGPoint(x: clip.sourceOrigin.x + offset.width, y: clip.sourceOrigin.y + offset.height)
        return insert(clip, at: origin, undoName: "Duplicate")
    }

    private func insert(_ clip: GraphClipboard, at origin: CGPoint, undoName: String) -> Set<NodeID> {
        let (nodes, edges) = clip.materialize(at: origin)
        let ids = Set(nodes.map(\.id))
        beginTransaction(undoName)
        apply(.insert(nodes: nodes, edges: edges))
        endTransaction()
        select(nodes: ids, mode: .replace)
        return ids
    }
}
