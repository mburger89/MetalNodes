import CoreGraphics
import MetalNodesCore

public enum SelectionMode: Sendable { case replace, add, toggle }

/// Selection lives in `viewState` (persisted, never undone — spec §5, §18.2).
extension EditorModel {
    public var selection: Set<NodeID> {
        get { viewState.selection }
        set { viewState.selection = newValue }
    }

    public func select(_ id: NodeID, mode: SelectionMode = .replace) {
        select(nodes: [id], mode: mode)
    }

    public func select(nodes ids: Set<NodeID>, mode: SelectionMode) {
        selectedWire = nil
        switch mode {
        // Replacing takes over the comment selection too (spec §21.4).
        case .replace: selection = ids; selectedComments = []
        case .add: selection.formUnion(ids)
        case .toggle: selection.formSymmetricDifference(ids)
        }
        pruneSelection()
    }

    /// The selection minus pseudo-nodes — what copy, cut, delete and group may act on (spec §20.8).
    public var editableSelection: Set<NodeID> { selection.filter { shape(of: $0)?.isPseudo != true } }

    public func selectAll() { select(nodes: Set(graph.nodes.keys), mode: .replace) }

    public func clearSelection() {
        selection = []
        selectedComments = []
        selectedWire = nil
    }

    /// ⌫: a selected wire wins over selected nodes; nodes and comments go together, in one
    /// undo step (spec §18.5, §21.4).
    public func deleteSelection() {
        if let wire = selectedWire {
            selectedWire = nil
            apply(.disconnect(wire))
            return
        }
        let ids = editableSelection
        let comments = selectedComments
        guard !ids.isEmpty || !comments.isEmpty else { return }
        selection = []
        selectedComments = []
        beginTransaction("Delete")
        if !ids.isEmpty { apply(.removeNodes(ids)) }
        if !comments.isEmpty { apply(.removeComments(comments)) }
        endTransaction()
    }

    /// Arrow keys: one undo step for the whole selection.
    public func nudgeSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for id in selection {
            guard let p = graph.nodes[id]?.position else { continue }
            moves[id] = CGPoint(x: p.x + delta.width, y: p.y + delta.height)
        }
        beginTransaction("Move")
        apply(.moveNodes(moves))
        endTransaction()
    }

    public func frame(of id: NodeID) -> CGRect? {
        guard let n = graph.nodes[id] else { return nil }
        return NodeGeometry.frame(for: n, shapes: shape(of:))
    }

    public var selectionBounds: CGRect? { NodeGeometry.bounds(of: selection, in: graph, shapes: shape(of:)) }
    public var contentBounds: CGRect? { NodeGeometry.bounds(of: graph.nodes.keys, in: graph, shapes: shape(of:)) }

    /// Topmost node under a canvas point. "Topmost" is the last in the canvas's draw order —
    /// the selection above everything else, then UUID order — so hit-testing agrees with what
    /// is actually drawn on top (spec §19.6).
    public func node(at point: CGPoint) -> NodeID? {
        let onTop = selection
        return graph.nodes.values
            .sorted { NodeGeometry.drawOrder($0, onTop: onTop) < NodeGeometry.drawOrder($1, onTop: onTop) }
            .last { NodeGeometry.frame(for: $0, shapes: shape(of:))?.contains(point) == true }?
            .id
    }
}
