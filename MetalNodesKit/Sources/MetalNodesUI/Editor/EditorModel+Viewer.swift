import MetalNodesCore

/// The ◉ flag (spec §9.3, §19.3, §20.5). View state, never undone; changing it recompiles.
extension EditorModel {
    public var viewer: SocketRef? { viewState.viewer }

    /// Setting a viewer also records how codegen reaches it — the instances dived through and the
    /// definition opened from the palette, as they stand *now* (spec §20.5, ruling R13). Popping
    /// back out therefore keeps the viewer alive; only losing a node on that route clears it.
    public func setViewer(_ ref: SocketRef?) {
        guard viewState.viewer != ref else { return }
        viewState.viewer = ref
        if let ref, document.node(ref.node)?.path != .root {
            viewState.viewerPath = viewState.editingStack
            viewState.viewerDefinition = viewState.editingDefinition
        } else {
            viewState.viewerPath = []
            viewState.viewerDefinition = nil
        }
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

    /// Clears a viewer the editor can no longer generate — a socket gone from the document, or a
    /// broken route to it. Returns true if it did. Never schedules a compile: its callers are
    /// changes that reclassify themselves.
    @discardableResult
    func pruneViewer() -> Bool {
        guard let v = viewState.viewer else { return false }
        guard GraphValidator.isValidViewer(v, in: document, registry: registry), viewerRouteIsIntact(v) else {
            viewState.viewer = nil
            viewState.viewerPath = []
            viewState.viewerDefinition = nil
            return true
        }
        return false
    }

    /// Walks the stored viewer route from its anchor — the opened definition, else the root. Every
    /// id on the path must still be a group instance in the graph the previous one opened, and the
    /// viewed node must live in the graph the walk ends on (spec §20.5).
    private func viewerRouteIsIntact(_ v: SocketRef) -> Bool {
        var path = GraphPath.root
        if let d = viewState.viewerDefinition {
            guard document.definitions[d] != nil else { return false }
            path = .definition(d)
        }
        for id in viewState.viewerPath {
            guard case .group(let g)? = document[path].nodes[id]?.kind, document.definitions[g] != nil else { return false }
            path = .definition(g)
        }
        return document[path].nodes[v.node] != nil
    }
}
