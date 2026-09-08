import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct UserLineErrorTests {
    /// The end-to-end promise: a real Metal error on the user's third line is reported as line 3.
    @Test func aCompilerErrorCarriesTheUsersLineNumber() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl("float a = 1.0;\nfloat b = 2.0;\nout = nonexistent_fn(a, b);")
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        g.inputs[SocketRef(t.id, "color")] = SocketRef(i.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc)
        let compiler = try ShaderCompiler(device: device)
        guard case .failure(_, let lines, _) = await compiler.compile(shader, generation: 1) else {
            Issue.record("expected a compile failure"); return
        }
        let errors = lines.filter { $0.severity == .error }
        #expect(!errors.isEmpty)
        // Every error inside the user's body resolves to a line the user can see.
        let userLines = errors.compactMap { shader.lineMap.userLine(forLine: $0.line) }
        #expect(userLines.contains(3))
    }
}
