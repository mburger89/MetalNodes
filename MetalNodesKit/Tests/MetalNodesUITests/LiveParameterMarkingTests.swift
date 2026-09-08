import Testing
import CoreGraphics
@testable import MetalNodesUI
@testable import MetalNodesCore

@Suite @MainActor struct LiveParameterMarkingTests {
    private func model(floats: Int) -> (EditorModel, [ParamPath]) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var paths: [ParamPath] = []
        for i in 0..<floats {
            var f = NodeInstance(kind: .builtin("input.float"), position: CGPoint(x: Double(i) * 20, y: 0))
            f.params["value"] = .float(Float(i))
            doc.root.nodes[f.id] = f
            paths.append(ParamPath(node: f.id, param: "value"))
        }
        return (EditorModel(document: doc, compiler: RecordingCompiler()), paths)
    }

    @Test func markingAParamAddsItInOrder() {
        let (m, p) = model(floats: 3)
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.toggleLiveParameter(p[2]))
        #expect(m.document.settings.liveParameters == [p[0], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
        #expect(m.liveParameterIndex(of: p[1]) == nil)
    }

    @Test func markingAgainUnmarksAndClosesTheGap() {
        let (m, p) = model(floats: 3)
        for path in p { _ = m.toggleLiveParameter(path) }
        #expect(m.toggleLiveParameter(p[0]))
        #expect(m.document.settings.liveParameters == [p[1], p[2]])
        #expect(m.liveParameterIndex(of: p[2]) == 1)
    }

    /// A CustomMaterial exposes one float4 — four floats, not five (spec §23.6, §24.5).
    @Test func theFifthIsRefusedWithANotice() {
        let (m, p) = model(floats: 5)
        for path in p.prefix(4) { #expect(m.toggleLiveParameter(path)) }
        #expect(!m.toggleLiveParameter(p[4]))
        #expect(m.document.settings.liveParameters.count == 4)
        #expect(m.notice != nil)
    }

    @Test func markingIsUndoable() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        m.undo()
        #expect(m.document.settings.liveParameters.isEmpty)
    }

    /// Deleting a marked node must not leave a live parameter pointing at nothing.
    @Test func deletingAMarkedNodeDropsItsLiveParameter() {
        let (m, p) = model(floats: 2)
        _ = m.toggleLiveParameter(p[0])
        _ = m.toggleLiveParameter(p[1])
        // `ParamPath` has no `.node` accessor (that's `SocketRef`'s) — the node id is the first
        // (only, for these single-node paths) element of `instancePath`, the same lookup every
        // other consumer (`doc.node(_:)`) uses.
        m.apply(.removeNodes([p[0].instancePath.first!]))
        #expect(m.document.settings.liveParameters == [p[1]])
    }

    /// The component letter shown beside each marked param, and used by the export.
    @Test func componentLettersFollowTheOrder() {
        #expect(EditorModel.liveParameterComponent(0) == "x")
        #expect(EditorModel.liveParameterComponent(3) == "w")
    }

    /// `DocumentSettings.liveParameters` carries no cap of its own — a hand-edited or migrated
    /// document can decode a fifth entry intact (`MaterialValidation`'s rule 6 is what refuses it,
    /// as a diagnostic, not the decoder). `liveParameterComponent` must not trap on that: it is what
    /// `InspectorView.documentSettings` calls, unconditionally, for every entry — and that pane is
    /// what an empty selection renders at the document root, so a bare `Array` subscript there would
    /// trap the instant such a document opened, before the user could do anything about it.
    @Test func theComponentPastTheFourthIsNilRatherThanTrapping() {
        #expect(EditorModel.liveParameterComponent(4) == nil)
        #expect(EditorModel.liveParameterComponent(100) == nil)
        #expect(EditorModel.liveParameterComponent(-1) == nil)
    }

    // MARK: `EditorModel.isLiveable` — fix round 2. Round 1 mutated this to an unconditional
    // `return false` and the full suite (304/77/527) still passed: nothing pinned that a widened
    // `isLiveable` actually widens, or that a still-generic, still-unresolved socket stays refused.
    // These four pin exactly the boundary the doc comment on the `SocketDecl` overload claims.

    private func floatInput() -> SocketDecl {
        SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0)))
    }

    private func genericVectorInput() -> SocketDecl {
        // `vector.length`'s `v`: generic, defaulting to `.float2` — never itself a float.
        SocketDecl(name: "v", type: .generic("T"), default: .value(.float2(.init(0, 0))))
    }

    @Test func aConcreteFloatUnwiredInputIsOffered() {
        #expect(EditorModel.isLiveable(floatInput(), resolvedType: nil))
    }

    @Test func aGenericSocketWithNoResolvedTypeIsNotOffered() {
        #expect(!EditorModel.isLiveable(genericVectorInput(), resolvedType: nil))
    }

    /// The deliberate widening past a literal "generics are never offered": a generic socket that
    /// *resolves* to `.float` (read from the emitter's own resolved type, never the lossy
    /// `TypeRef.concreteOrFloat` fallback) is offered.
    @Test func aGenericSocketThatResolvesToFloatIsOffered() {
        #expect(EditorModel.isLiveable(genericVectorInput(), resolvedType: .float))
    }

    /// The pair the doc comment defends: a concretely-non-float socket is never offered, whether or
    /// not a resolved type is known.
    @Test func aConcreteFloat3IsNeverOffered() {
        let decl = SocketDecl(name: "v", type: .concrete(.float3), default: .value(.float3(.init(0, 0, 0))))
        #expect(!EditorModel.isLiveable(decl, resolvedType: nil))
        #expect(!EditorModel.isLiveable(decl, resolvedType: .float3))
    }

    // MARK: `EditorModel.isLiveParameterReachable` — fix round 2. Round 1 mutated this to an
    // unconditional `return true` (never warn) and the full suite still passed. These pin the two
    // cases the reviewer named, against a real generated `UniformLayout` — the same way
    // `LiveParametersTests` (`MetalNodesCoreTests`) already builds one, no compiler/`MTLDevice`/
    // `EditorModel` instance required.

    /// One node wired to the terminal's `roughness`, one left unconnected — `reachable`'s path feeds
    /// the material, `orphan`'s exists in the document but reaches nothing.
    private func reachabilityDocument() -> (doc: ShaderDocument, reachable: ParamPath, orphan: ParamPath) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        var reachableNode = NodeInstance(kind: .builtin("input.float"), position: .zero)
        reachableNode.params["value"] = .float(0.5)
        g.nodes[reachableNode.id] = reachableNode
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(reachableNode.id, "out")
        var orphanNode = NodeInstance(kind: .builtin("input.float"), position: CGPoint(x: 40, y: 0))
        orphanNode.params["value"] = .float(0.2)
        g.nodes[orphanNode.id] = orphanNode
        doc.root = g
        return (doc, ParamPath(node: reachableNode.id, param: "value"), ParamPath(node: orphanNode.id, param: "value"))
    }

    @Test func aParamOnANodeFeedingTheTerminalGivesNoWarning() throws {
        let (doc, reachable, _) = reachabilityDocument()
        let layout = try ShaderGenerator.generate(doc, target: .realityKit).layout
        #expect(EditorModel.isLiveParameterReachable(reachable, in: layout))
    }

    @Test func aParamOnAnOrphanNodeWarns() throws {
        let (doc, _, orphan) = reachabilityDocument()
        let layout = try ShaderGenerator.generate(doc, target: .realityKit).layout
        #expect(!EditorModel.isLiveParameterReachable(orphan, in: layout))
    }

    /// Before any compile has landed there is no layout to contradict the mark — no warning.
    @Test func withNoCompiledLayoutYetThereIsNoWarning() {
        let (_, reachable, orphan) = reachabilityDocument()
        #expect(EditorModel.isLiveParameterReachable(reachable, in: nil))
        #expect(EditorModel.isLiveParameterReachable(orphan, in: nil))
    }
}

/// Final fix wave — F5 and F6.
@Suite @MainActor struct LiveParameterPruningTests {
    // MARK: F5 — a live path whose *param* is gone, with its node still present.

    /// `uv.x * k` with `k` live, edited to `uv.x`: the socket is gone from the node's shape, the
    /// export no longer reads the path, and the setting must not go on holding one of four slots
    /// for it. An unrelated live path on another node survives the reshape, and undo brings the
    /// pruned one back with the formula — it is the same change.
    @Test func editingAFormulaAwayFromALiveSocketDropsItsLiveParameter() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var e = NodeInstance(kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text("uv.x * k")
        var f = NodeInstance(kind: .builtin("input.float"), position: CGPoint(x: 40, y: 0))
        f.params["value"] = .float(1)
        doc.root.nodes[e.id] = e
        doc.root.nodes[f.id] = f
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        let k = ParamPath(node: e.id, param: "k")
        let other = ParamPath(node: f.id, param: "value")
        #expect(m.toggleLiveParameter(k))
        #expect(m.toggleLiveParameter(other))

        m.apply(.setParam(e.id, ExpressionNode.formulaParam, .text("uv.x")))
        #expect(m.document.settings.liveParameters == [other])

        m.undo()
        #expect(m.document.settings.liveParameters == [k, other])
        #expect(m.document.root.nodes[e.id]?.params[ExpressionNode.formulaParam] == .text("uv.x * k"))
    }

    /// A socket the formula still names keeps its mark — the prune is by the node's *current*
    /// shape, not a blanket drop on every formula edit.
    @Test func editingAFormulaThatKeepsTheSocketKeepsItsLiveParameter() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var e = NodeInstance(kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text("uv.x * k")
        doc.root.nodes[e.id] = e
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        let k = ParamPath(node: e.id, param: "k")
        _ = m.toggleLiveParameter(k)
        m.apply(.setParam(e.id, ExpressionNode.formulaParam, .text("uv.y + k")))
        #expect(m.document.settings.liveParameters == [k])
    }

    /// The same class on a definition instance: removing the definition's input drops the param
    /// from every instance, and the live mark on it goes with it — the prune `.removeSocket`
    /// already ran now judges the param half of the path too.
    @Test func removingADefinitionInputDropsItsLiveParameter() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        let a = ParamPath(node: instance.id, param: "a")
        #expect(m.toggleLiveParameter(a))
        m.apply(.removeSocket(id, .input, "a"))
        #expect(m.document.settings.liveParameters.isEmpty)
    }

    /// Renaming the input is not a removal: `GroupOperations.renameSocket` carries each instance's
    /// value across, and the live mark follows the same way rather than being pruned.
    @Test func renamingADefinitionInputCarriesItsLiveParameterAcross() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        #expect(m.toggleLiveParameter(ParamPath(node: instance.id, param: "a")))
        m.apply(.renameSocket(id, .input, from: "a", to: "gain"))
        #expect(m.document.settings.liveParameters == [ParamPath(node: instance.id, param: "gain")])
    }

    /// The name the mark follows to is the one `GroupOperations.renameSocket` actually *wrote*,
    /// not the raw text the inspector passed in: the operation sanitises ("my gain" becomes
    /// `my_gain`), and a path rewritten to the raw name would name a socket that does not exist
    /// and be pruned on the next line — the silent unmark the follow exists to prevent. The
    /// identifier-clean rename above cannot see this; only a name sanitisation rewrites can.
    @Test func renamingADefinitionInputToANameThatNeedsSanitisingStillCarriesTheMark() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        let m = EditorModel(document: doc, compiler: RecordingCompiler())
        let id = try #require(m.newCustomCodeDefinition(at: .zero))
        let instance = try #require(m.document.root.nodes.values.first { $0.kind == .group(id) })
        #expect(m.toggleLiveParameter(ParamPath(node: instance.id, param: "a")))
        m.apply(.renameSocket(id, .input, from: "a", to: "my gain"))
        let written = try #require(m.document.definitions[id]?.inputs.first?.name)
        #expect(written == "my_gain")
        #expect(m.document.settings.liveParameters == [ParamPath(node: instance.id, param: written)])
    }

    // MARK: F6 — `isLiveable(_ decl: ParamDecl)` is concretely `.float`, not any `.value`.

    /// Widening the check to `if case .value = decl.kind` passed the whole suite: nothing pinned
    /// that a declared vector param is refused the Live control. A `CustomMaterial`'s `float4`
    /// holds one float per component, so only a `.value(.float, …)` param may be offered.
    @Test func aDeclaredFloatParamIsLiveableAndAnyOtherKindIsNot() {
        let float = ParamDecl(name: "k", kind: .value(.float, range: nil), defaultValue: .float(1))
        #expect(EditorModel.isLiveable(float))
        let float3 = ParamDecl(name: "v", kind: .value(.float3, range: nil), defaultValue: .float3(.zero))
        #expect(!EditorModel.isLiveable(float3))
        let color = ParamDecl(name: "c", kind: .value(.color, range: nil), defaultValue: .float4(.init(0, 0, 0, 1)))
        #expect(!EditorModel.isLiveable(color))
        let int = ParamDecl(name: "n", kind: .value(.int, range: nil), defaultValue: .int(1))
        #expect(!EditorModel.isLiveable(int))
        let mode = ParamDecl(name: "mode", kind: .enumeration(["a", "b"]), defaultValue: .enumCase("a"))
        #expect(!EditorModel.isLiveable(mode))
        let text = ParamDecl(name: "formula", kind: .text(multiline: false), defaultValue: .text(""))
        #expect(!EditorModel.isLiveable(text))
    }
}
