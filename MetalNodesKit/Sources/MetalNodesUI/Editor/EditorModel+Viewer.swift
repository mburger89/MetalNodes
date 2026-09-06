import MetalNodesCore

/// The ◉ flag (spec §9.3, §19.3). View state, never undone; changing it recompiles.
extension EditorModel {
    public var viewer: SocketRef? { viewState.viewer }

    public func setViewer(_ ref: SocketRef?) {
        guard viewState.viewer != ref else { return }
        viewState.viewer = ref
        scheduleCompile()
    }

    public func toggleViewer(_ ref: SocketRef) { setViewer(viewState.viewer == ref ? nil : ref) }

    /// The node's first declared output, the socket the header badge and ⌘⇧V act on.
    public func firstOutput(of id: NodeID) -> SocketRef? {
        guard let n = document.root.nodes[id], case .builtin(let defID) = n.kind,
              let first = registry[defID]?.outputs.first else { return nil }
        return SocketRef(id, first.name)
    }

    public func toggleViewerOnSelection() {
        guard selection.count == 1, let id = selection.first, let ref = firstOutput(of: id) else { return }
        toggleViewer(ref)
    }

    public var viewedType: SocketType? {
        guard let v = viewer else { return nil }
        return resolvedTypes[v.node]?.outputTypes[v.socket]
    }

    /// Clears a viewer whose socket no longer exists. Returns true if it did.
    @discardableResult
    func pruneViewer() -> Bool {
        guard let v = viewState.viewer, !GraphValidator.isValidViewer(v, in: document.root, registry: registry) else { return false }
        viewState.viewer = nil
        return true
    }
}
