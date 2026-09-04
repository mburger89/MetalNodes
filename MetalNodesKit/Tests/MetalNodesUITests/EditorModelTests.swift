import Testing
import Foundation
import Metal
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Records generations and never publishes, so tests can count compiles deterministically.
actor RecordingCompiler: ShaderCompiling {
    private(set) var generations: [UInt64] = []
    func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult {
        generations.append(generation)
        return .superseded(generation: generation)
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
        #expect(DocumentChange.moveNode(id, to: .zero).changeClass == .cosmetic)
        #expect(DocumentChange.setParam(id, "value", .float(1)).changeClass == .parameter)
        #expect(DocumentChange.setParam(id, "op", .enumCase("sine")).changeClass == .topology)
        #expect(DocumentChange.connect(from: SocketRef(id, "a"), to: SocketRef(id, "b")).changeClass == .topology)
        #expect(DocumentChange.disconnect(SocketRef(id, "a")).changeClass == .topology)
        #expect(DocumentChange.removeNode(id).changeClass == .topology)
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
        m.apply(.moveNode(uv.id, to: CGPoint(x: 5, y: 5)))
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
        m.apply(.removeNode(node(m, "output.fragment").id))
        await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.message.contains("Fragment Output") })
        #expect(await c.generations == [1])
    }

    @Test func parameterChangeWritesUniformsWithoutRecompiling() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
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
        guard let device = MTLCreateSystemDefaultDevice() else { return }
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
}
