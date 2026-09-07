import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct CustomCodeCompileTests {
    /// A body whose loop has no terminating condition of its own. Without hardening this either
    /// hangs the GPU when dispatched or, if `break` were misplaced outside the loop, fails to
    /// *compile* outright. With correct hardening the program compiles and links: the guard
    /// declares outside the loop, the check-and-break lands as the loop body's first statement,
    /// and the loop provably exits at the cap regardless of `a`.
    @Test func aRunawayLoopStillProducesALinkedPipeline() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Runaway")
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl("while (in_a > 0.0) { out += 0.0001; }")
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let inst = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[inst.id] = inst
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(inst.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .fragment)
        #expect(shader.source.contains("mn_loopGuard0"))
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else { Issue.record("compile failed: \(result)"); return }
    }

    /// The Expression node's substituted formula compiles too — the second custom-code path.
    @Test func anExpressionCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let uv = NodeInstance(id: NodeID(), kind: .builtin("input.uv"), position: .zero)
        var e = NodeInstance(id: NodeID(), kind: .builtin(ExpressionNode.id), position: .zero)
        e.params[ExpressionNode.formulaParam] = .text("float4(uv, 0.5 * uv.x, 1.0)")
        e.params[ExpressionNode.outputTypeParam] = .enumCase("float4")
        for n in [terminal, uv, e] { g.nodes[n.id] = n }
        g.inputs[SocketRef(e.id, "uv")] = SocketRef(uv.id, "uv")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(e.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .fragment)
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success = result else { Issue.record("compile failed: \(result)"); return }
    }
}
