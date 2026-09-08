import Foundation
import CoreGraphics
import MetalNodesCore

/// Groups: the five operations, the editing stack, and the recursion refusal (spec §20.3, §20.6).
extension EditorModel {
    /// Folds the selection into a fresh definition and selects its instance. Nil — with a notice,
    /// so a refused ⌘G is not silent (spec §20.6) — when nothing real is selected or the cut could
    /// not be typed.
    @discardableResult
    public func groupSelection(name: String? = nil) -> GroupID? {
        let ids = editableSelection
        guard !ids.isEmpty else {
            showNotice("Selection cannot be grouped")
            return nil
        }
        let before = Set(document.definitions.keys)
        apply(.groupSelection(ids, name: name))
        guard let created = Set(document.definitions.keys).subtracting(before).first else {
            showNotice("Selection cannot be grouped")
            return nil
        }
        return created
    }

    /// A Custom MSL node is born empty — unlike a group, which is born from a selection (spec
    /// §24.3). It arrives with a working one-in/one-out body so it compiles before its first edit.
    /// The input is only in scope inside the emitted function as `in_a` (`GroupCodegen.systemParams`
    /// spells every declared input `in_<name>`), which is why the body reads `in_a`, not `a`.
    public static let customCodeStarter = """
    // Your code runs inside a function. Inputs are parameters; assign to the outputs.
    out = in_a * 2.0;
    """

    /// Creates a Custom MSL definition and places one instance of it, as a single undo step. `nil`
    /// — the active graph is itself a `.msl` definition's inert "canvas" (Task 16's HARD
    /// REQUIREMENT; `apply` refuses the whole change before either half lands) — when the document
    /// could not take the new definition and its instance together. Explained with a notice
    /// (Task 17's HARD REQUIREMENT): the refusal was silent through Task 16.
    @discardableResult
    public func newCustomCodeDefinition(at point: CGPoint) -> GroupID? {
        var def = GroupDefinition(name: GroupOperations.uniqueDefinitionName("Custom Code", in: document))
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl(Self.customCodeStarter)
        let instance = NodeInstance(kind: .group(def.id), position: point)
        // One change, so one undo step covers the definition and its instance together.
        apply(.insert(nodes: [instance], edges: [], definitions: [def]))
        guard document.definitions[def.id] != nil else {
            showNotice("Exit this Custom Code definition first — one can't hold another")
            return nil
        }
        select(instance.id)
        return def.id
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

    /// True when the editor is inside a definition whose body is text rather than a graph — the
    /// canvas is replaced by the code editor (Task 17), and until it is, `apply` refuses any
    /// change that would touch the (inert) active graph (Task 16's HARD REQUIREMENT).
    public var isEditingCode: Bool {
        guard case .definition(let id) = activePath else { return false }
        if case .msl = document.definitions[id]?.body { return true }
        return false
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

    // MARK: A definition's own socket editor (spec §20.6, §24.3; Task 17's HARD REQUIREMENT)

    /// Adds a socket directly on `id` — a `.msl` definition's own way of gaining one, since it has
    /// no pseudo-node `+` to wire into (`expose(_:in:decl:name:edge:)` is the `.graph` counterpart,
    /// reached by dragging a wire). Returns the name it actually landed under, uniqued against its
    /// siblings by `GroupOperations.addSocket`, or `nil` with a notice explaining why — a name
    /// reserved by the generated function's own parameter list, or (an output) a texture type,
    /// which no `.msl` result struct can express.
    @discardableResult
    public func addSocket(to id: GroupID, kind: SocketKind, decl: SocketDecl) -> String? {
        guard let def = document.definitions[id] else { return nil }
        let before = (kind == .input ? def.inputs : def.outputs).count
        apply(.addSocket(id, kind, decl))
        let after = kind == .input ? document.definitions[id]?.inputs : document.definitions[id]?.outputs
        guard let after, after.count == before + 1 else {
            if kind == .output, decl.type == .concrete(.texture) {
                showNotice("An output can't be a texture — a “.msl” result can only hold plain values")
            } else {
                showNotice(reservedSocketNotice(StitchableCodegen.sanitizedName(decl.name), kind: kind))
            }
            return nil
        }
        return after.last?.name
    }

    /// Renames a socket directly on `id` — what `SocketRow`'s rename field commits through.
    /// Returns whether it actually landed; on `false` the caller should snap its draft back, as it
    /// already did, but now with a notice up rather than a silent revert. A no-op rename (the
    /// sanitised name already matches `old`) counts as landed — there is nothing to explain.
    @discardableResult
    public func renameSocket(_ id: GroupID, _ kind: SocketKind, from old: String, to newName: String) -> Bool {
        guard let def = document.definitions[id] else { return false }
        let sanitized = StitchableCodegen.sanitizedName(newName)
        guard sanitized != old else { return true }
        apply(.renameSocket(id, kind, from: old, to: newName))
        let names = (kind == .input ? document.definitions[id]?.inputs : document.definitions[id]?.outputs)?.map(\.name) ?? []
        guard !names.contains(old), names.contains(sanitized) else {
            if GroupOperations.mslReservedSocketName(sanitized, kind: kind, in: def) {
                showNotice(reservedSocketNotice(sanitized, kind: kind))
            } else {
                showNotice("“\(sanitized)” is already the name of another \(kind == .input ? "input" : "output")")
            }
            return false
        }
        return true
    }

    /// The message for a name the generated function's own signature already uses (spec §24.5's
    /// system parameters, or the other namespace's `in_<name>` spelling) — says what to do, not
    /// just what failed, since the reader is the person who has to pick another name right now.
    private func reservedSocketNotice(_ name: String, kind: SocketKind) -> String {
        "“\(name)” is reserved — the generated function already has a parameter by that name. Pick a different \(kind == .input ? "input" : "output") name."
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
        // `apply` can refuse the whole change without this call ever being told — most concretely
        // the HARD REQUIREMENT gate, inside a `.msl` definition's inert "canvas". Reporting success
        // for a node that was never actually inserted would be worse than the honest `nil` above:
        // the caller (a palette drag-and-drop, `GraphCanvasView.swift`) would report an accepted
        // drop that did nothing, and `select` below would select a phantom id.
        guard graph.nodes[n.id] != nil else {
            // The only way `.addNode` can land here refused is the canvas gate: nothing else makes
            // `perform` a no-op for it. Task 17's HARD REQUIREMENT: explain it rather than repeat
            // Task 16's silent `nil`.
            showNotice("A Custom Code definition can't hold other nodes — exit it first")
            return nil
        }
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

    /// Drops the stack from the first entry that is no longer a group instance, forgets a
    /// deleted `editingDefinition` — a dive can outlive what it dived into (spec §20.3) — and
    /// drops the parked camera of any definition the document no longer holds, so leaving a
    /// graph that is being deleted cannot leave its camera behind for good.
    func pruneEditingStack() {
        viewState.cameras = viewState.cameras.filter { path, _ in
            guard case .definition(let id) = path else { return true }
            return document.definitions[id] != nil
        }
        if let i = viewState.editingStack.firstIndex(where: { id in
            guard let n = document.node(id)?.node, case .group(let g) = n.kind, document.definitions[g] != nil else { return true }
            return false
        }) {
            viewState.editingStack = Array(viewState.editingStack.prefix(i))
        }
        if let d = viewState.editingDefinition, document.definitions[d] == nil { viewState.editingDefinition = nil }
    }
}
