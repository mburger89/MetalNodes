import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorGroupsTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler(), pasteboard: MemoryPasteboard())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String, op: String? = nil) -> NodeID {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) && (op == nil || $0.params["op"] == .enumCase(op!)) }!.id
    }

    @Test func groupSelectionIsOneUndoStepAndSelectsTheInstance() async {
        let m = model()
        m.start(); await m.awaitIdle()
        let mul = node(m, "math.math", op: "multiply"), sine = node(m, "math.math", op: "sine")
        m.select(nodes: [mul, sine], mode: .replace)
        let gid = m.groupSelection()
        #expect(gid != nil)
        #expect(m.document.definitions.count == 1)
        #expect(m.selection.count == 1)
        let inst = m.selection.first!
        #expect(m.document.root.nodes[inst]?.kind == .group(gid!))
        #expect(m.undoManager.undoActionName == "Group")
        m.undo()
        #expect(m.document.definitions.isEmpty)
        #expect(m.document.root.nodes[mul] != nil)
    }

    @Test func diveInBindsChangesToTheDefinitionGraph() async {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        #expect(m.activePath == GraphPath.definition(gid))
        #expect(m.selection.isEmpty)
        #expect(m.viewState.editingStack == [inst])
        #expect(m.breadcrumb.map(\.title) == ["Shader", "Group"])
        let added = m.addNode(defID: "input.float", at: .zero)!
        #expect(m.document.definitions[gid]!.graph.nodes[added] != nil)
        #expect(m.document.root.nodes[added] == nil)
        m.exitGroup()
        #expect(m.activePath == GraphPath.root)
        #expect(m.viewState.editingStack.isEmpty)
        m.editDefinition(gid)
        #expect(m.activePath == GraphPath.definition(gid))
        #expect(m.viewState.editingDefinition == gid)
        m.popToLevel(0)
        #expect(m.activePath == GraphPath.root)
        #expect(m.viewState.editingDefinition == nil)
    }

    /// A "Group" definition holding a nested "Group 2" instance, with the editor back at the root.
    private func nestedGroups(_ m: EditorModel) -> (outer: GroupID, inner: GroupID, innerInstance: NodeID) {
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let outer = m.groupSelection()!
        m.diveIn(m.selection.first!)
        m.select(nodes: Set(m.graph.nodes.values.filter { $0.kind == .builtin("math.math") }.map(\.id)), mode: .replace)
        let inner = m.groupSelection()!
        let instance = m.selection.first!
        m.popToLevel(0)
        return (outer, inner, instance)
    }

    /// Ruling R16: a definition opened from the palette is level 1, and diving from it stacks above.
    @Test func aPaletteOpenedDefinitionOccupiesItsOwnBreadcrumbLevel() {
        let m = model()
        let g = nestedGroups(m)
        m.editDefinition(g.outer)
        m.diveIn(g.innerInstance)
        #expect(m.breadcrumb.map(\.title) == ["Shader", "Group", "Group 2"])
        #expect(m.breadcrumb.map(\.level) == [0, 1, 2])
        #expect(m.activePath == GraphPath.definition(g.inner))
        m.exitGroup()
        #expect(m.activePath == GraphPath.definition(g.outer))
        #expect(m.viewState.editingDefinition == g.outer)
        #expect(m.viewState.editingStack.isEmpty)
        m.exitGroup()
        #expect(m.activePath == GraphPath.root)
        #expect(m.viewState.editingDefinition == nil)
    }

    /// What gates the Edit menu's "Exit Group" (spec §20.8).
    @Test func exitGroupIsOfferedOnlyBelowTheRoot() {
        let m = model()
        #expect(m.canExitGroup == false)
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        #expect(m.canExitGroup)
        m.exitGroup()
        #expect(m.canExitGroup == false)
        m.editDefinition(gid)
        #expect(m.canExitGroup)
    }

    @Test func popToLevelOneReturnsToThePaletteOpenedDefinition() {
        let m = model()
        let g = nestedGroups(m)
        m.editDefinition(g.outer)
        m.diveIn(g.innerInstance)
        m.popToLevel(1)
        #expect(m.activePath == GraphPath.definition(g.outer))
        #expect(m.viewState.editingStack.isEmpty)
    }

    /// `Group` on a node that is being viewed moves it out of the active graph, so the viewer —
    /// which recorded no route — has to go with it.
    @Test func groupingTheViewedNodeClearsTheViewer() {
        let m = model()
        let mul = node(m, "math.math", op: "multiply"), sine = node(m, "math.math", op: "sine")
        m.setViewer(SocketRef(sine, "out"))
        m.select(nodes: [mul, sine], mode: .replace)
        m.groupSelection()
        #expect(m.viewer == nil)
        #expect(m.selection.count == 1)
    }

    @Test func undoingAGroupLeavesTheDiveBehind() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        m.groupSelection()
        m.diveIn(m.selection.first!)
        m.undo()
        #expect(m.viewState.editingStack.isEmpty)
        #expect(m.activePath == GraphPath.root)
    }

    @Test func deletingTheEditedDefinitionLeavesIt() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.apply(.removeNodes([m.selection.first!]))          // the definition is now unused
        m.editDefinition(gid)
        m.apply(.deleteDefinition(gid))
        #expect(m.viewState.editingDefinition == nil)
        #expect(m.document.definitions.isEmpty)
    }

    @Test func renamingADefinitionRebuilds() {
        // The name is part of the emitted function's identifier (spec §20.4, ruling R14).
        #expect(DocumentChange.renameDefinition(GroupID(), "X").changeClass == ChangeClass.topology)
        #expect(DocumentChange.setDefinitionAccent(GroupID(), .cyan).changeClass == ChangeClass.cosmetic)
    }

    @Test func pseudoNodesCannotBeDeletedOrCopied() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        let gin = m.document.definitions[gid]!.inputNode!
        m.select(gin)
        m.deleteSelection()
        #expect(m.document.definitions[gid]!.graph.nodes[gin] != nil)
        #expect(m.clipboardData() == nil)
    }

    @Test func ungroupAndMakeUniqueGoThroughApply() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.makeUniqueSelection()
        #expect(m.document.definitions.count == 2)
        #expect(m.document.root.nodes[inst]?.kind != NodeKind.group(gid))
        m.ungroupSelection()
        #expect(m.document.root.nodes[inst] == nil)
        #expect(m.selection.count == 2)
        #expect(m.undoManager.undoActionName == "Ungroup")
    }

    @Test func recursionIsRefusedWithANotice() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        #expect(m.addInstance(of: gid, at: .zero) == nil)
        #expect(m.notice == "Group cannot contain itself")
        #expect(m.document.definitions[gid]!.graph.nodes.values.contains { $0.kind == .group(gid) } == false)
    }

    @Test func socketEditsPropagateAndAreOneUndoStep() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.apply(.renameSocket(gid, .input, from: "time", to: "t"))
        #expect(m.document.root.inputs[SocketRef(inst, "t")] != nil)
        m.apply(.removeSocket(gid, .input, "t"))
        #expect(m.document.root.inputs[SocketRef(inst, "t")] == nil)
        m.undo()
        #expect(m.document.root.inputs[SocketRef(inst, "t")] != nil)
    }

    // MARK: Exposing sockets by wiring into `+` (spec §20.6)

    /// Groups the sample's Multiply → Sine chain and dives into it. The definition comes out with
    /// two inputs (Time and the Float's value) and one output, `out`, fed by Sine.
    private func divedGroup(_ m: EditorModel) -> (definition: GroupID, instance: NodeID) {
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        return (gid, inst)
    }
    private func inner(_ m: EditorModel, op: String) -> NodeID {
        m.graph.nodes.values.first { $0.params["op"] == .enumCase(op) }!.id
    }

    @Test func exposeOutputAddsAWiredOutputInOneUndoStep() {
        let m = model()
        let g = divedGroup(m)
        let mul = inner(m, op: "multiply")
        let name = m.exposeOutput(from: SocketRef(mul, "out"), in: g.definition)
        #expect(name == "out2")                                   // "out" is taken by the grouped edge
        let def = m.document.definitions[g.definition]!
        #expect(def.outputs.map(\.name) == ["out", "out2"])
        #expect(def.outputs.last?.type == TypeRef.concrete(.float))
        #expect(def.graph.inputs[SocketRef(def.outputNode!, "out2")] == SocketRef(mul, "out"))
        #expect(m.shape(of: g.instance)?.outputs.map(\.name) == ["out", "out2"])   // the instance outside
        #expect(m.undoManager.undoActionName == "Expose Output")
        m.undo()
        #expect(m.document.definitions[g.definition]?.outputs.map(\.name) == ["out"])
        #expect(m.document.definitions[g.definition]?.graph.inputs[SocketRef(def.outputNode!, "out2")] == nil)
    }

    @Test func exposeInputAddsAValuedInputWiredFromGroupInput() {
        let m = model()
        let g = divedGroup(m)
        let sine = inner(m, op: "sine")
        let before = m.document.definitions[g.definition]!.inputs.count
        let name = m.exposeInput(to: SocketRef(sine, "b"), in: g.definition)
        #expect(name == "b")
        let def = m.document.definitions[g.definition]!
        #expect(def.inputs.count == before + 1)
        #expect(def.inputs.last?.name == "b")
        #expect(def.inputs.last?.default == SocketDefault.value(.float(0)))
        #expect(def.graph.inputs[SocketRef(sine, "b")] == SocketRef(def.inputNode!, "b"))
        #expect(m.shape(of: g.instance)?.inputs.last?.name == "b")                 // the instance's new slot
        #expect(m.undoManager.undoActionName == "Expose Input")
        m.undo()
        #expect(m.document.definitions[g.definition]?.inputs.count == before)
        #expect(m.document.definitions[g.definition]?.graph.inputs[SocketRef(sine, "b")] == nil)
    }

    /// Both helpers name the socket after the wire's end and refuse what they cannot type.
    /// UV → Separate → Combine → Normalize → Output. `Normalize`'s output is `.generic("T")`, so
    /// only the wire feeding it says it is a `float3` — the type has to survive the trip into a
    /// definition (ruling R20).
    private func vectorModel() -> (EditorModel, NodeID) {
        func n(_ id: String, _ x: CGFloat) -> NodeInstance { NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: 0)) }
        let uv = n("input.uv", 0), sep = n("vector.separate", 200), comb = n("vector.combine", 400)
        let norm = n("vector.normalize", 600), out = n("output.fragment", 800)
        var g = Graph()
        for node in [uv, sep, comb, norm, out] { g.nodes[node.id] = node }
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(sep.id, "v"))
        g.connect(SocketRef(sep.id, "x"), to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"), to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(comb.id, "out"), to: SocketRef(norm.id, "v"))
        g.connect(SocketRef(norm.id, "out"), to: SocketRef(out.id, "color"))
        var doc = ShaderDocument()
        doc.root = g
        let m = EditorModel(document: doc, compiler: RecordingCompiler(), pasteboard: MemoryPasteboard())
        m.debounceInterval = .milliseconds(5)
        return (m, norm.id)
    }

    @Test func exposeOutputTakesTheTypeResolvedInsideTheDefinition() async {
        let (m, norm) = vectorModel()
        m.start(); await m.awaitIdle()
        m.select(nodes: [norm], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        await m.awaitIdle()
        #expect(m.resolvedTypes[norm]?.outputTypes["out"] == SocketType.float3)
        #expect(m.exposeOutput(from: SocketRef(norm, "out"), in: gid) == "out2")
        #expect(m.document.definitions[gid]?.outputs.last?.type == TypeRef.concrete(.float3))
    }

    @Test func exposingRefusesOutsideItsDefinition() {
        let m = model()
        let g = divedGroup(m)
        let mul = inner(m, op: "multiply")
        m.exitGroup()                                             // back in the root
        #expect(m.exposeOutput(from: SocketRef(mul, "out"), in: g.definition) == nil)
        #expect(m.exposeInput(to: SocketRef(mul, "a"), in: g.definition) == nil)
        #expect(m.document.definitions[g.definition]?.outputs.count == 1)
    }

    /// The `+` socket is never itself exposable, and a viewer badge skips it (spec §20.6, §20.8).
    @Test func theViewerBadgeSkipsThePlusSocket() {
        let m = model()
        let g = divedGroup(m)
        let gin = m.document.definitions[g.definition]!.inputNode!
        #expect(m.shape(of: gin)?.outputs.last?.name == "+")
        #expect(m.firstOutput(of: gin)?.socket != "+")
        let gout = m.document.definitions[g.definition]!.outputNode!
        #expect(m.firstOutput(of: gout) == nil)                   // Group Output has no outputs at all
    }

    @Test func viewerInsideADefinitionCompilesThroughTheStack() async {
        let m = model()
        m.start(); await m.awaitIdle()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        let sine = m.document.definitions[gid]!.graph.nodes.values.first { $0.params["op"] == .enumCase("sine") }!.id
        m.setViewer(SocketRef(sine, "out")); await m.awaitIdle()
        #expect(m.generatedSource.contains("_view("))
        #expect(m.generatedSource.contains("u.viewerMin"))
        m.exitGroup()
        m.apply(.removeNodes([inst])); await m.awaitIdle()
        #expect(m.viewer == nil)
    }

    /// Ruling R13: the viewer remembers the route it was set through, so popping out keeps it —
    /// only losing an instance on that route clears it (spec §20.5).
    @Test func poppingOutKeepsTheViewerUntilTheInstanceIsDeleted() async {
        let m = model()
        m.start(); await m.awaitIdle()
        let uv = node(m, "input.uv"), tint = node(m, "input.color")
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        let sine = m.document.definitions[gid]!.graph.nodes.values.first { $0.params["op"] == .enumCase("sine") }!.id
        m.setViewer(SocketRef(sine, "out")); await m.awaitIdle()
        m.exitGroup()
        m.apply(.moveNodes([uv: CGPoint(x: 40, y: 40)]))
        m.apply(.removeNodes([tint])); await m.awaitIdle()          // an unrelated root edit that prunes
        #expect(m.viewer == SocketRef(sine, "out"))
        #expect(m.generatedSource.contains("_view("))
        m.apply(.removeNodes([inst])); await m.awaitIdle()
        #expect(m.viewer == nil)
        #expect(m.viewState.viewerPath.isEmpty)
    }

    @Test func pastingAnInstanceIntoItsOwnDefinitionIsRefused() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.copySelection()
        m.diveIn(m.selection.first!)
        let before = m.document.definitions[gid]!.graph
        #expect(m.paste(at: .zero).isEmpty)
        #expect(m.notice == "Group cannot contain itself")
        #expect(m.document.definitions[gid]!.graph == before)
    }

    @Test func pasteBringsDefinitionsAlong() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.copySelection()
        var d = m.document
        d.definitions[gid] = nil                                   // simulate a document that lacks it
        d.root.nodes[m.selection.first!] = nil
        m.apply(.restore(d))
        m.paste(at: .zero)
        #expect(m.document.definitions[gid] != nil)
    }
}
