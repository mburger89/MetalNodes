import Foundation
import CoreGraphics
import MetalNodesCore

extension EditorModel {
    /// Comments copy on their own, so a selected note alone is enough (spec §21.4).
    public var canCopy: Bool { !editableSelection.isEmpty || !selectedComments.isEmpty }
    public var canPaste: Bool { pasteboard.read(type: Self.pasteboardType) != nil }

    /// The selection encoded as the `pasteboardType` payload — with the definitions it references
    /// (spec §20.7) and the comments it holds (spec §21.4) — or nil when nothing copyable is selected.
    public func clipboardData() -> Data? {
        let clip = GraphClipboard.extract(selection, comments: selectedComments, from: graph, document: document, textures: textures)
        guard !clip.isEmpty else { return nil }
        return try? JSONEncoder().encode(clip)
    }

    public func copySelection() {
        if let data = clipboardData() { pasteboard.write(data, type: Self.pasteboardType) }
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
              clip.formatVersion <= GraphClipboard.currentFormatVersion, !clip.isEmpty else { return [] }
        let origin = point ?? CGPoint(x: clip.sourceOrigin.x + 24, y: clip.sourceOrigin.y + 24)
        return insert(clip, at: origin, undoName: "Paste")
    }

    /// Copy + paste without the pasteboard; one `Duplicate` step.
    @discardableResult
    public func duplicateSelection(offset: CGSize = CGSize(width: 24, height: 24)) -> Set<NodeID> {
        guard canCopy else { return [] }
        let clip = GraphClipboard.extract(selection, comments: selectedComments, from: graph, document: document, textures: textures)
        let origin = CGPoint(x: clip.sourceOrigin.x + offset.width, y: clip.sourceOrigin.y + offset.height)
        return insert(clip, at: origin, undoName: "Duplicate")
    }

    private func insert(_ clip: GraphClipboard, at origin: CGPoint, undoName: String) -> Set<NodeID> {
        let (nodes, edges) = clip.materialize(at: origin)
        guard !refusesRecursion(nodes, definitions: clip.definitions) else { return [] }
        let (stickies, frames) = clip.materializeComments(at: origin)
        let ids = Set(nodes.map(\.id))
        // Only ids the clipboard has both the manifest entry and bytes for become insertable
        // assets; `.insert` itself skips any the destination already has (spec §13, §21.2).
        let assets: [AssetID: (info: AssetInfo, data: Data)] = clip.assetInfos.reduce(into: [:]) { acc, entry in
            if let data = clip.textures[entry.key] { acc[entry.key] = (info: entry.value, data: data) }
        }
        beginTransaction(undoName)
        apply(.insert(nodes: nodes, edges: edges, definitions: clip.definitions, assets: assets, stickies: stickies, frames: frames))
        endTransaction()
        // Both sets at once: what was pasted is what is selected, comments included (spec §21.4).
        select(nodes: ids,
               comments: Set(stickies.map { CommentID.sticky($0.id) }).union(frames.map { CommentID.frame($0.id) }),
               mode: .replace)
        return ids
    }

    /// Spec §20.8, ruling R15: a payload that would make the definition being edited contain itself
    /// is refused whole, with a notice. Judged after the merge plan and on a document that already
    /// holds what the plan would insert — a *diverged* definition arrives as a fresh copy, which is
    /// not the host and does not recurse.
    private func refusesRecursion(_ nodes: [NodeInstance], definitions: [GroupDefinition]) -> Bool {
        var merged = document
        let plan = ClipboardMerge.plan(definitions: definitions, into: merged)
        for d in plan.insert { merged.definitions[d.id] = d }
        for n in ClipboardMerge.apply(plan, to: nodes) {
            guard case .group(let g) = n.kind,
                  GroupDependencies.wouldRecurse(placing: g, in: activePath, document: merged) else { continue }
            showNotice("\(merged.definitions[g]?.name ?? "Group") cannot contain itself")
            return true
        }
        return false
    }
}
