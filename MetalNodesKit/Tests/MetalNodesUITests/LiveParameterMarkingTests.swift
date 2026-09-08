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
