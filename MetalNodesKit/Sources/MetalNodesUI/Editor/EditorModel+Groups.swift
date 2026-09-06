import Foundation
import CoreGraphics
import MetalNodesCore

/// Groups: the five operations, the editing stack, and the recursion refusal (spec §20.3, §20.6).
extension EditorModel {
    /// Folds the selection into a fresh definition and selects its instance. Nil when nothing
    /// real is selected or the cut could not be typed.
    @discardableResult
    public func groupSelection(name: String? = nil) -> GroupID? {
        let ids = editableSelection
        guard !ids.isEmpty else { return nil }
        let before = Set(document.definitions.keys)
        apply(.groupSelection(ids, name: name))
        return Set(document.definitions.keys).subtracting(before).first
    }

    public func ungroupSelection() {
        guard let id = selectedInstance else { return }
        apply(.ungroup(id))
    }

    public func makeUniqueSelection() {
        guard let id = selectedInstance else { return }
        apply(.makeUnique(id))
    }

    /// The one selected group instance in the active graph, which Ungroup, Make Unique and
    /// "Edit Group" act on.
    public var selectedInstance: NodeID? {
        guard selection.count == 1, let id = selection.first, case .group? = graph.nodes[id]?.kind else { return nil }
        return id
    }

    // MARK: Dive in / out (spec §20.3)

    /// Pushes an instance of the active graph. Keeps `editingDefinition`, so a definition opened
    /// from the palette stays the anchor the viewer is generated through (ruling R8).
    public func diveIn(_ instance: NodeID) {
        guard case .group? = graph.nodes[instance]?.kind else { return }
        viewState.editingStack.append(instance)
        clearSelection()
    }

    public func exitGroup() { popToLevel(max(0, viewState.editingStack.count - 1)) }

    /// Level 0 is the root; level n keeps the first n stack entries.
    public func popToLevel(_ level: Int) {
        if level == 0 {
            viewState.editingStack = []
            viewState.editingDefinition = nil
        } else {
            viewState.editingStack = Array(viewState.editingStack.prefix(level))
        }
        clearSelection()
    }

    /// "Edit" in the palette: a definition with no instance to dive through (spec §20.6).
    public func editDefinition(_ id: GroupID) {
        guard document.definitions[id] != nil else { return }
        viewState.editingStack = []
        viewState.editingDefinition = id
        clearSelection()
    }

    /// `Shader › Fbm › Turbulence` — one entry per level, `level` being what `popToLevel` takes.
    public var breadcrumb: [(title: String, level: Int)] {
        var out = [(title: "Shader", level: 0)]
        for (i, instance) in viewState.editingStack.enumerated() {
            guard let n = document.node(instance)?.node, case .group(let g) = n.kind else { continue }
            out.append((n.customTitle ?? document.definitions[g]?.name ?? "Group", i + 1))
        }
        if viewState.editingStack.isEmpty, let d = viewState.editingDefinition, let def = document.definitions[d] {
            out.append((def.name, 1))
        }
        return out
    }

    // MARK: Placement

    /// Places an instance of `id` in the active graph; refused with a notice when it would make a
    /// definition contain itself (spec §4.6, §20.8).
    @discardableResult
    public func addInstance(of id: GroupID, at point: CGPoint) -> NodeID? {
        guard let def = document.definitions[id] else { return nil }
        guard !GroupDependencies.wouldRecurse(placing: id, in: activePath, document: document) else {
            showNotice("\(def.name) cannot contain itself")
            return nil
        }
        let n = NodeInstance(kind: .group(id), position: point)
        apply(.addNode(n))
        select(n.id)
        return n.id
    }

    /// Shows `text` in the preview pane's diagnostics strip for 3 s (spec §20.8). A later notice
    /// supersedes this one: the timer only clears the text it set.
    func showNotice(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, notice == text else { return }
            notice = nil
        }
    }

    /// Drops the stack from the first entry that is no longer a group instance, and forgets a
    /// deleted `editingDefinition` — a dive can outlive what it dived into (spec §20.3).
    func pruneEditingStack() {
        if let i = viewState.editingStack.firstIndex(where: { id in
            guard let n = document.node(id)?.node, case .group(let g) = n.kind, document.definitions[g] != nil else { return true }
            return false
        }) {
            viewState.editingStack = Array(viewState.editingStack.prefix(i))
        }
        if let d = viewState.editingDefinition, document.definitions[d] == nil { viewState.editingDefinition = nil }
    }
}
