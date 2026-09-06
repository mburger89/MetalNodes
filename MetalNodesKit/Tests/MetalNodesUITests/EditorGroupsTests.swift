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
