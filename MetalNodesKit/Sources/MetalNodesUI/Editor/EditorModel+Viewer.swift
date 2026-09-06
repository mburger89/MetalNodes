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

    /// The node's first declared output, the socket the header badge and ⌘⇧V act on. Resolves
    /// document-wide, so it also works on a node inside a definition (spec §20.3).
    public func firstOutput(of id: NodeID) -> SocketRef? {
        guard let first = shape(of: id)?.outputs.first else { return nil }
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

    /// Clears a viewer the editor can no longer generate. Returns true if it did.
    ///
    /// Two ways to lose one: the socket is gone from the document, or — for a viewer inside a
    /// definition — the editor no longer has a route to it. Codegen reaches such a node only
    /// through the editing stack or the definition opened from the palette (spec §20.5), so once
    /// the active path leaves that definition (typically because an instance on the stack was
    /// deleted, which `pruneEditingStack` truncates) the viewer has nothing to render through.
    @discardableResult
    func pruneViewer() -> Bool {
        pruneEditingStack()
        guard let v = viewState.viewer else { return false }
        guard let location = document.node(v.node), GraphValidator.isValidViewer(v, in: document, registry: registry),
              location.path == .root || location.path == activePath else {
            viewState.viewer = nil
            return true
        }
        return false
    }
}
