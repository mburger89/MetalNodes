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

    /// Breadcrumb levels (ruling R16): 0 is the root, a palette-opened definition occupies level 1,
    /// and the stack follows. So the deepest level is `base + editingStack.count`.
    private var levelBase: Int { viewState.editingDefinition == nil ? 0 : 1 }

    /// Whether there is a level to pop: the stack is non-empty, or a definition is open from the
    /// palette. Gates the Edit menu's "Exit Group" (spec §20.8).
    public var canExitGroup: Bool { activePath != .root }

    /// Pops exactly one level — out of the innermost instance, or out of a palette-opened
    /// definition once the stack above it is gone.
    public func exitGroup() { popToLevel(max(0, levelBase + viewState.editingStack.count - 1)) }

    /// Level 0 is the root and clears everything; any deeper level keeps the palette-opened
    /// definition and truncates the stack to what sits above it.
    public func popToLevel(_ level: Int) {
        if level == 0 {
            viewState.editingStack = []
            viewState.editingDefinition = nil
        } else {
            viewState.editingStack = Array(viewState.editingStack.prefix(max(0, level - levelBase)))
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
        if let d = viewState.editingDefinition, let def = document.definitions[d] { out.append((def.name, 1)) }
        let base = levelBase
        for (i, instance) in viewState.editingStack.enumerated() {
            guard let n = document.node(instance)?.node, case .group(let g) = n.kind else { continue }
            out.append((n.customTitle ?? document.definitions[g]?.name ?? "Group", base + i + 1))
        }
        return out
    }

    // MARK: Exposing sockets by wiring into `+` (spec §20.6)

    /// Adds an output to `definition` named after `source`'s socket and wires `source` into it —
    /// what dropping a wire on the `GroupOutput`'s `+` does. One undo step; nil when the socket
    /// cannot be typed, or when the definition is not the graph being edited (a `.connect` always
    /// lands in the active graph).
    @discardableResult
    public func exposeOutput(from source: SocketRef, in definition: GroupID) -> String? {
        guard activePath == .definition(definition), let gout = document.definitions[definition]?.outputNode,
              let type = DropResolver.outputType(of: source, graph: graph, shapes: activeShapes, resolved: resolvedTypes),
              type != .texture else { return nil }
        return expose(.output, in: definition, decl: SocketDecl(name: source.socket, type: .concrete(type)),
                      name: "Expose Output") { Edge(to: SocketRef(gout, $0), from: source) }
    }

    /// Adds an input to `definition` named after `target`'s socket, defaulted to that type's zero,
    /// and wires the `GroupInput` into `target` — what a wildcard drag from the `+` does.
    @discardableResult
    public func exposeInput(to target: SocketRef, in definition: GroupID) -> String? {
        guard activePath == .definition(definition), let gin = document.definitions[definition]?.inputNode,
              let type = DropResolver.inputType(of: target, graph: graph, shapes: activeShapes, resolved: resolvedTypes),
              type != .texture else { return nil }
        let decl = SocketDecl(name: target.socket, type: .concrete(type), default: .value(GroupOperations.zero(type)))
        return expose(.input, in: definition, decl: decl, name: "Expose Input") { Edge(to: target, from: SocketRef(gin, $0)) }
    }

    /// The shared half: add the socket, then wire the edge the caller builds from the name the
    /// document actually gave it (`addSocket` uniques against the definition's other sockets).
    private func expose(_ kind: SocketKind, in definition: GroupID, decl: SocketDecl, name: String,
                        edge: (String) -> Edge) -> String? {
        func sockets() -> [SocketDecl] {
            let def = document.definitions[definition]
            return (kind == .input ? def?.inputs : def?.outputs) ?? []
        }
        let before = sockets().count
        beginTransaction(name)
        apply(.addSocket(definition, kind, decl))
        // Only the socket this call appended may be wired: a refused `addSocket` would otherwise
        // leave the last existing one to be wired by mistake.
        guard sockets().count == before + 1, let created = sockets().last?.name else {
            cancelTransaction()
            return nil
        }
        let e = edge(created)
        apply(.connect(from: e.from, to: e.to))
        endTransaction()
        return created
    }

    /// The active graph's shapes, as `NodeGeometry` and `DropResolver` take them.
    private var activeShapes: (NodeInstance) -> NodeShape? { { self.shape(of: $0) } }

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
