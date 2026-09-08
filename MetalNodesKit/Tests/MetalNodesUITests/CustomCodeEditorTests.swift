import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

@Suite @MainActor struct CustomCodeEditorTests {
    private func model() -> EditorModel {
        EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())
    }

    @Test func aNewDefinitionStartsWithOneInputOneOutputAndAWorkingBody() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: CGPoint(x: 40, y: 40)))
        let def = try #require(m.document.definitions[id])
        #expect(def.inputs.map(\.name) == ["a"])
        #expect(def.outputs.map(\.name) == ["out"])
        guard case .msl(let body) = def.body else { Issue.record("not an msl body"); return }
        // The starter's own text refers to the input by its bare declared name; the input is only
        // ever in scope inside the emitted function as `in_a` (`GroupCodegen.systemParams`), which
        // is what the compile test below actually exercises.
        #expect(body.contains("out = in_a * 2.0;"))
    }

    /// It also places an instance — an invisible definition would be unreachable.
    @Test func creatingOnePlacesAnInstance() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: CGPoint(x: 40, y: 40)))
        let instances = m.document.root.nodes.values.filter { $0.kind == .group(id) }
        #expect(instances.count == 1)
        #expect(instances.first?.position == CGPoint(x: 40, y: 40))
    }

    /// The starter body validates clean once it is actually part of a program: a bare
    /// `ShaderDocument()` has no Fragment Output node at all (an unrelated pre-existing complaint
    /// that would fire for an *empty* document too), so this wires the new instance's `out` into
    /// one — the minimum a document needs to be otherwise complete — and checks that nothing about
    /// the new definition or its starter body adds an error on top of that.
    @Test func aNewDefinitionValidatesClean() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        m.apply(.addNode(terminal))
        m.apply(.connect(from: SocketRef(instance.id, "out"), to: SocketRef(terminal.id, "color")))
        let errs = GraphValidator.validate(document: m.document, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
        #expect(errs.isEmpty, "\(errs.map(\.message))")
    }

    @Test func creatingOneIsASingleUndoStep() throws {
        let m = model()
        let before = m.document
        _ = try #require(m.newCustomCodeDefinition(at: .zero))
        m.undo()
        #expect(m.document.definitions.count == before.definitions.count)
        #expect(m.document.root.nodes.count == before.root.nodes.count)
    }

    /// Diving into a code definition is legal and lands on it.
    @Test func divingIntoACodeDefinitionOpensIt() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        m.diveIn(instance.id)
        #expect(m.activePath == .definition(id))
        #expect(m.isEditingCode)
    }

    /// A graph definition is not code, and the code editor must not claim it.
    @Test func aGraphDefinitionIsNotEditingCode() {
        let m = model()
        var g = GroupDefinition(name: "G")
        g.body = .graph(Graph())
        m.apply(.addDefinition(g))
        m.editDefinition(g.id)
        #expect(m.activePath == .definition(g.id))
        #expect(!m.isEditingCode)
    }

    // MARK: HARD REQUIREMENT — the canvas is gated shut on a `.msl` body, not merely absorbed by
    // `GroupDefinition.graph`'s silent-drop setter (which does not cover everything `.insert`
    // carries — see `EditorModel.apply`).

    /// A plain node-graph edit issued while a `.msl` definition is the active graph must be
    /// refused outright: no document mutation, no undo entry, not merely "absorbed" into a
    /// structurally-equal document that happens not to register an undo step.
    @Test func aCanvasEditInsideACodeDefinitionIsRefused() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        m.editDefinition(id)
        #expect(m.isEditingCode)
        let before = m.document
        let versionBefore = m.undoStackVersion
        m.apply(.addNode(NodeInstance(kind: .builtin("input.uv"), position: .zero)))
        #expect(m.document == before)
        #expect(m.undoStackVersion == versionBefore)
    }

    /// The concrete leak `.insert` would otherwise open: it also carries new *definitions*, which
    /// `document.definitions[d.id] = d` writes regardless of the active graph's body — so without
    /// the gate, creating a second Custom Code node while inside a first one would add a real,
    /// undo-visible definition while silently dropping its paired instance. The gate refuses the
    /// whole change instead.
    @Test func creatingANestedCodeNodeInsideACodeDefinitionIsRefused() throws {
        let m = model()
        let outerID = try #require(m.newCustomCodeDefinition(at: .zero))
        m.editDefinition(outerID)
        #expect(m.isEditingCode)
        let definitionsBefore = m.document.definitions.count
        let created = m.newCustomCodeDefinition(at: CGPoint(x: 10, y: 10))
        #expect(created == nil)
        #expect(m.document.definitions.count == definitionsBefore)
    }
}
