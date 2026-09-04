import Testing
import Foundation
import Metal
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Records generations and never publishes, so tests can count compiles deterministically.
actor RecordingCompiler: ShaderCompiling {
    private(set) var generations: [UInt64] = []
    private(set) var fastMathFlags: [Bool] = []
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        generations.append(generation)
        fastMathFlags.append(fastMath)
        return .superseded(generation: generation)
    }
}

/// Always fails with one warning and one error line so severity mapping can be observed.
actor WarningCompiler: ShaderCompiling {
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        .failure(message: "synthetic", lines: [
            CompileLine(line: 1, severity: .warning, message: "header warning"),      // line 1 has no node owner
            CompileLine(line: 999, severity: .error, message: "nowhere"),
        ], generation: generation)
    }
}

@MainActor
@Suite struct EditorModelTests {
    private func model(_ compiler: any ShaderCompiling) -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: compiler)
        m.debounceInterval = .milliseconds(5)
        return m
    }

    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func classification() {
        let id = NodeID()
        #expect(DocumentChange.moveNodes([id: .zero]).changeClass == .cosmetic)
        #expect(DocumentChange.setParam(id, "value", .float(1)).changeClass == .parameter)
        #expect(DocumentChange.setParam(id, "op", .enumCase("sine")).changeClass == .topology)
        #expect(DocumentChange.connect(from: SocketRef(id, "a"), to: SocketRef(id, "b")).changeClass == .topology)
        #expect(DocumentChange.disconnect(SocketRef(id, "a")).changeClass == .topology)
        #expect(DocumentChange.removeNodes([id]).changeClass == .topology)
        #expect(DocumentChange.setTitle(id, "x").changeClass == .cosmetic)
        #expect(DocumentChange.insert(nodes: [], edges: []).changeClass == .topology)
    }

    @Test func removeNodesPrunesSelectionAndDropsWires() async {
        let m = model(RecordingCompiler())
        let uv = node(m, "input.uv"), sep = node(m, "vector.separate")
        m.viewState.selection = [uv.id, sep.id]
        m.apply(.removeNodes([uv.id]))
        #expect(m.viewState.selection == [sep.id])
        #expect(m.document.root.inputs.values.contains { $0.node == uv.id } == false)
    }

    @Test func insertAddsNodesThenWiresInOneChange() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        let a = NodeInstance(kind: .builtin("input.time")), b = NodeInstance(kind: .builtin("math.math"))
        m.apply(.insert(nodes: [a, b], edges: [Edge(to: SocketRef(b.id, "a"), from: SocketRef(a.id, "time"))]))
        await m.awaitIdle()
        #expect(m.document.root.source(feeding: SocketRef(b.id, "a")) == SocketRef(a.id, "time"))
        #expect(await c.generations.count == 2)
    }

    @Test func setTitleIsCosmeticAndEmptyClears() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        let uv = node(m, "input.uv")
        m.apply(.setTitle(uv.id, "Coords"))
        #expect(m.document.root.nodes[uv.id]?.customTitle == "Coords")
        m.apply(.setTitle(uv.id, ""))
        #expect(m.document.root.nodes[uv.id]?.customTitle == nil)
        await m.awaitIdle()
        #expect(await c.generations.count == 1)
    }

    @Test func startCompilesOnce() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start()
        await m.awaitIdle()
        #expect(await c.generations == [1])
        #expect(!m.generatedSource.isEmpty)
        #expect(m.resolvedTypes.count == 11)
    }

    @Test func cosmeticChangeDoesNotCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let uv = node(m, "input.uv")
        m.apply(.moveNodes([uv.id: CGPoint(x: 5, y: 5)]))
        await m.awaitIdle()
        #expect(await c.generations.count == 1)
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 5, y: 5))
    }

    @Test func rapidTopologyChangesCoalesceIntoOneCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let sine = node(m, "math.math")
        for op in ["cosine", "sine", "fract"] { m.apply(.setParam(sine.id, "op", .enumCase(op))) }
        await m.awaitIdle()
        #expect(await c.generations == [1, 2])
    }

    @Test func awaitIdleWaitsForEditsThatLandMidAwait() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let sine = node(m, "math.math")
        m.apply(.setParam(sine.id, "op", .enumCase("cosine")))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            m.apply(.setParam(sine.id, "op", .enumCase("sine")))
        }
        await m.awaitIdle()
        #expect(await c.generations.count == 2)
    }

    @Test func invalidGraphReportsDiagnosticsAndDoesNotCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        m.apply(.removeNodes([node(m, "output.fragment").id]))
        await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.message.contains("Fragment Output") })
        #expect(await c.generations == [1])
    }

    @Test func parameterChangeWritesUniformsWithoutRecompiling() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — these tests need a GPU")
        let real = try ShaderCompiler(device: device)
        let m = model(real)
        m.start(); await m.awaitIdle()
        let pipeline = try #require(m.preview.pipeline)
        let speed = node(m, "input.float")
        let before = try #require(m.preview.uniforms).bytes
        m.apply(.setParam(speed.id, "value", .float(0.9)))
        await m.awaitIdle()
        #expect(m.preview.uniforms?.bytes != before)
        #expect(m.preview.pipeline?.generation == pipeline.generation)
        #expect(m.document.root.nodes[speed.id]?.params["value"] == .float(0.9))
    }

    @Test func compileFailureKeepsLastGoodPipelineAndMapsLines() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — these tests need a GPU")
        let m = model(try ShaderCompiler(device: device))
        m.start(); await m.awaitIdle()
        let good = try #require(m.preview.pipeline)
        // A bad template can only come from a bad registry; simulate via a broken definition.
        let broken = NodeDef(id: "t.broken", title: "Broken", category: .utility,
                             outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                             body: .template("{out.out} = this_is_not_msl;"))
        let reg = try NodeRegistry(BuiltinNodes.all + [broken])
        let m2 = EditorModel(document: .sample(), compiler: try ShaderCompiler(device: device), registry: reg)
        m2.debounceInterval = .milliseconds(5)
        m2.start(); await m2.awaitIdle()
        let b = NodeInstance(kind: .builtin("t.broken"))
        let out = node(m2, "output.fragment")
        m2.apply(.addNode(b))
        m2.apply(.connect(from: SocketRef(b.id, "out"), to: SocketRef(out.id, "color")))
        await m2.awaitIdle()
        #expect(m2.preview.lastError != nil)
        #expect(m2.preview.pipeline != nil)
        #expect(m2.diagnostics.contains { $0.node == b.id })
        _ = good
    }

    @Test func compilerSeverityMapsToDiagnosticsAndUnmappedLinesSurvive() async {
        let m = EditorModel(document: .sample(), compiler: WarningCompiler())
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.severity == .warning && $0.message == "header warning" && $0.node == nil })
        #expect(m.diagnostics.contains { $0.severity == .error && $0.message == "nowhere" })
        #expect(m.preview.pipeline == nil)
        #expect(m.preview.lastError == "synthetic")
    }

    @Test func fastMathSettingReachesTheCompiler() async {
        let c = RecordingCompiler()
        var doc = ShaderDocument.sample()
        doc.settings.fastMath = false
        let m = EditorModel(document: doc, compiler: c)
        m.start(); await m.awaitIdle()
        #expect(await c.fastMathFlags == [false])
    }
}
