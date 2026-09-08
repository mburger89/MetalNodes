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
        guard !refusesRecursion(nodes, definitions: clip.definitions),
              !refusesTerminalIntoDefinition(nodes) else { return [] }
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
        // `apply` can refuse the whole change without this call ever being told — most concretely
        // the HARD REQUIREMENT gate, inside a `.msl` definition's inert "canvas" (`.insert` is one
        // of the changes it refuses outright). Reporting the clipboard's own ids as "landed" for a
        // paste or duplicate that inserted nothing would be the same lie `addInstance`/`addSocket`
        // were fixed to stop telling (fix round 1, I4 — flagged, deliberately left, in this task's
        // first pass; the earlier commit's justification that it was safe because `canCopy` is
        // false inside a `.msl` definition is true of `duplicateSelection`, which reads the
        // selection, but not of `paste`, which does not, so this is the honest fix rather than a
        // rationale for continuing to skip it). Currently unreachable in practice — the canvas
        // gesture, its context menu, and the pasteboard command all live on `GraphCanvasView`,
        // which is unmounted for exactly as long as this gate is shut — but that is a property of
        // today's UI wiring, not of this method's own contract.
        guard ids.isSubset(of: graph.nodes.keys),
              Set(stickies.map(\.id)).isSubset(of: graph.stickies.keys),
              Set(frames.map(\.id)).isSubset(of: graph.frames.keys) else {
            showNotice("\(undoName) isn't possible right now")
            return []
        }
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

    /// Mirrors `GroupOperations.group`'s refusal (spec §23.2): a Fragment/Material Output is never
    /// valid inside a definition, so a paste that would drop one there — the copy having been made
    /// from the root, or from an already-corrupt document — is refused whole, with a notice, rather
    /// than silently landing a terminal where `validate` will only catch it afterward.
    private func refusesTerminalIntoDefinition(_ nodes: [NodeInstance]) -> Bool {
        guard case .definition = activePath, let terminal = nodes.first(where: { GraphValidator.isTerminal($0.kind) }) else { return false }
        let label = terminal.kind == .builtin(GraphValidator.materialTerminalID) ? "Material Output" : "Fragment Output"
        showNotice("\(label) cannot be pasted into a group")
        return true
    }
}
