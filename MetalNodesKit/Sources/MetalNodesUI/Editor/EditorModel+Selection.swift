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
        case .replace: selection = ids
        case .add: selection.formUnion(ids)
        case .toggle: selection.formSymmetricDifference(ids)
        }
        pruneSelection()
    }

    public func selectAll() { select(nodes: Set(document.root.nodes.keys), mode: .replace) }

    public func clearSelection() {
        selection = []
        selectedWire = nil
    }

    /// ⌫: a selected wire wins over selected nodes (spec §18.5).
    public func deleteSelection() {
        if let wire = selectedWire {
            selectedWire = nil
            apply(.disconnect(wire))
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        apply(.removeNodes(ids))
    }

    /// Arrow keys: one undo step for the whole selection.
    public func nudgeSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for id in selection {
            guard let p = document.root.nodes[id]?.position else { continue }
            moves[id] = CGPoint(x: p.x + delta.width, y: p.y + delta.height)
        }
        beginTransaction("Move")
        apply(.moveNodes(moves))
        endTransaction()
    }

    public func frame(of id: NodeID) -> CGRect? {
        guard let n = document.root.nodes[id] else { return nil }
        return NodeGeometry.frame(for: n, registry: registry)
    }

    public var selectionBounds: CGRect? { NodeGeometry.bounds(of: selection, in: document.root, registry: registry) }
    public var contentBounds: CGRect? { NodeGeometry.bounds(of: document.root.nodes.keys, in: document.root, registry: registry) }

    /// Topmost node under a canvas point. "Topmost" is the last in the canvas's draw order —
    /// the selection above everything else, then UUID order — so hit-testing agrees with what
    /// is actually drawn on top (spec §19.6).
    public func node(at point: CGPoint) -> NodeID? {
        let onTop = selection
        return document.root.nodes.values
            .sorted { NodeGeometry.drawOrder($0, onTop: onTop) < NodeGeometry.drawOrder($1, onTop: onTop) }
            .last { NodeGeometry.frame(for: $0, registry: registry)?.contains(point) == true }?
            .id
    }
}
