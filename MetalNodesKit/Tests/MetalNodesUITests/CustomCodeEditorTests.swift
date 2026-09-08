import Testing
import Foundation
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
    ///
    /// `.addNode` alone does not pin this: `GroupDefinition.graph`'s silent-drop setter already
    /// absorbs it on its own (the getter hands back a throwaway empty `Graph()`, the node is added
    /// to *that*, and the setter then drops the whole thing) — this assertion holds even with the
    /// gate in `apply` deleted. `.insert(assets:)` is the one write the drop cannot reach:
    /// `document.settings.assets[id]` and `EditorModel.textures[id]` are written directly in
    /// `perform`, never through `document[path]`, so only the gate stops them. Both are asserted so
    /// deleting the gate fails this test (verified).
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

        let assetID = AssetID()
        let info = AssetInfo(name: "leaked", pixelSize: CGSize(width: 4, height: 4), fileExtension: "png")
        m.apply(.insert(nodes: [], edges: [], assets: [assetID: (info: info, data: Data([1, 2, 3, 4]))]))
        #expect(m.document == before)
        #expect(m.document.settings.assets[assetID] == nil)
        #expect(m.textures[assetID] == nil)
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

    /// `addInstance(of:at:)` must not report success for a node the gate refused to insert — a
    /// non-`nil` id the graph never actually holds would tell a palette drag-and-drop it landed
    /// when it did nothing (spec — Task 16 fix round 1, IMPORTANT 2).
    ///
    /// Task 16 left this refusal silent on purpose and pinned `m.notice == nil` here as the
    /// honest record of that gap; Task 17's HARD REQUIREMENT is to close it, so this pin is
    /// superseded — the refusal must now explain itself (spec §20.8's `showNotice` pattern).
    @Test func placingAnUnrelatedDefinitionInsideACodeDefinitionIsHonestlyRefused() throws {
        let m = model()
        let codeID = try #require(m.newCustomCodeDefinition(at: .zero))
        // A second, unrelated definition to place — placing `codeID` itself inside its own
        // definition would also hit the recursion refusal, which already returns `nil` honestly;
        // this proves the *gate* path is equally honest.
        var other = GroupDefinition(name: "Other")
        other.body = .graph(Graph())
        m.apply(.addDefinition(other))
        m.editDefinition(codeID)
        #expect(m.isEditingCode)
        let nodesBefore = m.graph.nodes.count
        let placed = m.addInstance(of: other.id, at: .zero)
        #expect(placed == nil)
        #expect(m.graph.nodes.count == nodesBefore)
        #expect(m.notice != nil)
    }

    // MARK: HARD REQUIREMENT (Task 17) — the silent refusals get a `showNotice` explanation.

    /// A second Custom Code node while already inside one's editor is refused by the HARD
    /// REQUIREMENT gate (Task 16); Task 17 must not let that refusal stay silent.
    @Test func creatingANestedCodeNodeShowsANotice() throws {
        let m = model()
        let outerID = try #require(m.newCustomCodeDefinition(at: .zero))
        m.editDefinition(outerID)
        #expect(m.notice == nil)
        let created = m.newCustomCodeDefinition(at: CGPoint(x: 10, y: 10))
        #expect(created == nil)
        #expect(m.notice != nil)
    }

    /// Renaming a socket to a name the generated function's own signature already uses (spec
    /// §24.5's system parameters) is refused — and must explain *why*, not just fail silently
    /// (SocketRow.commit previously just snapped the text field back).
    @Test func renamingAnOutputToASystemParameterNameIsRefusedWithAnExplanation() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let ok = m.renameSocket(id, .output, from: "out", to: "time")
        #expect(ok == false)
        let def = try #require(m.document.definitions[id])
        #expect(def.outputs.map(\.name) == ["out"])   // untouched
        let notice = try #require(m.notice)
        #expect(notice.contains("time"))
        #expect(notice.localizedCaseInsensitiveContains("reserved"))
    }

    /// Adding an input whose parameter spelling (`in_<name>`) collides with an *existing output's*
    /// own bare name is the cross-namespace reserved case (§24.5's `mslNameCollides` `.input`
    /// branch) — also refused, also explained.
    @Test func addingAnInputWhoseParameterSpellingCollidesWithAnExistingOutputIsRefused() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        // An output literally named "in_q" — legal on its own, nothing collides yet.
        #expect(m.addSocket(to: id, kind: .output, decl: SocketDecl(name: "in_q", type: .concrete(.float))) == "in_q")
        // An input named "q" would be spelled `in_q` in the function body — exactly the name the
        // output above already declares in that scope.
        let created = m.addSocket(to: id, kind: .input, decl: SocketDecl(name: "q", type: .concrete(.float)))
        #expect(created == nil)
        let def = try #require(m.document.definitions[id])
        #expect(def.inputs.map(\.name) == ["a"])   // nothing appended
        #expect(m.notice != nil)
    }

    /// `addSocket` on a `.msl` definition is what the code-definition's own socket editor (Task
    /// 17, no pseudo-node `+` to wire into) routes through — a reserved name is refused there too.
    @Test func addingASocketWithASystemParameterNameIsRefusedWithAnExplanation() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let created = m.addSocket(to: id, kind: .output, decl: SocketDecl(name: "uv", type: .concrete(.float)))
        #expect(created == nil)
        let def = try #require(m.document.definitions[id])
        #expect(def.outputs.map(\.name) == ["out"])   // nothing appended
        let notice = try #require(m.notice)
        #expect(notice.contains("uv"))
    }

    /// A texture-typed output has no valid `.msl` result-struct field (`GroupOperations.addSocket`'s
    /// own guard) — same wrapper, a different reason, still explained rather than silently dropped.
    @Test func addingATextureTypedOutputIsRefusedWithAnExplanation() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let created = m.addSocket(to: id, kind: .output, decl: SocketDecl(name: "tex", type: .concrete(.texture)))
        #expect(created == nil)
        #expect(m.notice != nil)
    }

    /// A plain, non-colliding name succeeds and lands as an ordinary socket — the notice
    /// machinery must not fire on the success path.
    @Test func addingAnOrdinarySocketSucceedsWithNoNotice() throws {
        let m = model()
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let created = m.addSocket(to: id, kind: .input, decl: SocketDecl(name: "b", type: .concrete(.float)))
        #expect(created == "b")
        #expect(m.notice == nil)
        #expect(m.document.definitions[id]?.inputs.map(\.name) == ["a", "b"])
    }

    /// Two `.msl` definitions never collide with each other's reserved names — the guard is
    /// purely about one definition's own generated signature.
    @Test func renamingASocketOnAGraphDefinitionIsUnaffectedByTheMSLReservedNames() throws {
        let m = model()
        var g = GroupDefinition.make(name: "G")
        g.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        m.apply(.addDefinition(g))
        // "time" is a system-parameter name — refused as reserved on an *output* of a `.msl`
        // definition (see `renamingAnOutputToASystemParameterNameIsRefusedWithAnExplanation`
        // above) — but collides with nothing on a `.graph` body: `mslNameCollides` only ever
        // applies to a `.msl` one (`GroupOperations.swift`'s own doc comment).
        let ok = m.renameSocket(g.id, .output, from: "out", to: "time")
        #expect(ok)
        #expect(m.document.definitions[g.id]?.outputs.map(\.name) == ["time"])
    }
}

@Suite @MainActor struct CodeEditorTests {
    private func model() -> (EditorModel, GroupID) {
        let m = EditorModel(document: ShaderDocument(), compiler: RecordingCompiler())
        let id = m.newCustomCodeDefinition(at: .zero)!
        return (m, id)
    }

    @Test func editingTheBodyIsOneUndoableChange() throws {
        let (m, id) = model()
        m.apply(.setDefinitionBody(id, "out = a;"))
        guard case .msl(let b) = try #require(m.document.definitions[id]).body else {
            Issue.record("not an msl body"); return
        }
        #expect(b == "out = a;")
        m.undo()
        guard case .msl(let back) = try #require(m.document.definitions[id]).body else {
            Issue.record("not an msl body"); return
        }
        #expect(back == EditorModel.customCodeStarter)
    }

    /// The user typed three lines; the compiler complained about the third. The row says 3.
    @Test func diagnosticsAreListedAtTheUsersOwnLineNumbers() throws {
        let (m, id) = model()
        var d = Diagnostic(.error, "use of undeclared identifier 'qq'")
        d.userLine = 3
        m.diagnostics = [d]
        let rows = m.codeDiagnostics(for: id)
        #expect(rows.count == 1)
        #expect(rows.first?.line == 3)
        #expect(rows.first?.message.contains("qq") == true)
    }

    /// A diagnostic with no user line came from generated scaffolding, not from the user's text.
    @Test func aDiagnosticWithNoUserLineIsFiledAtZero() throws {
        let (m, id) = model()
        m.diagnostics = [Diagnostic(.warning, "unused variable 'p'")]
        #expect(m.codeDiagnostics(for: id).first?.line == 0)
    }

    /// Rows come back in line order, so the list reads top-to-bottom like the text does.
    @Test func rowsAreSortedByLine() throws {
        let (m, id) = model()
        var a = Diagnostic(.error, "second"); a.userLine = 7
        var b = Diagnostic(.error, "first"); b.userLine = 2
        m.diagnostics = [a, b]
        #expect(m.codeDiagnostics(for: id).map(\.line) == [2, 7])
    }

    /// The definition's own body text is what the editor shows — never a hardened or rewritten
    /// version of it (Global Constraints; spec §24.4).
    @Test func theEditorShowsExactlyWhatWasTyped() throws {
        let (m, id) = model()
        let typed = "for (int i = 0; i < 100000; ++i) { out += a; }"
        m.apply(.setDefinitionBody(id, typed))
        #expect(m.codeBody(for: id) == typed)
    }

    /// A diagnostic naming a *different* definition is not this editor's problem.
    @Test func aDiagnosticForAnotherDefinitionIsExcluded() throws {
        let (m, id) = model()
        var d = Diagnostic(.error, "elsewhere")
        d.userLine = 1
        d.definition = GroupID()   // some other definition, not `id`
        m.diagnostics = [d]
        #expect(m.codeDiagnostics(for: id).isEmpty)
    }
}
