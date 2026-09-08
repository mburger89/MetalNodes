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

    /// The same end-to-end promise for an Expression node's own formula, closed in fix round 1:
    /// before this, no Expression line was ever recorded as user text at all, so `userLine` was
    /// `nil` for every diagnostic inside one. `cos()` is legal as far as `MSLScanner`/
    /// `CustomCodeValidation` are concerned — neither checks arity — but `cos` takes exactly one
    /// argument, so it is a genuine Metal compile error, not merely a constructed one.
    @Test func anExpressionsCompilerErrorCarriesTheUsersLineNumber() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("cos()"), "type": .enumCase("float")])
        g.nodes[t.id] = t; g.nodes[expr.id] = expr
        g.inputs[SocketRef(t.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc)
        let compiler = try ShaderCompiler(device: device)
        guard case .failure(_, let lines, _) = await compiler.compile(shader, generation: 1) else {
            Issue.record("expected a compile failure"); return
        }
        let errors = lines.filter { $0.severity == .error }
        #expect(!errors.isEmpty)
        // The formula is the Expression's only line, so every error inside it is user line 1.
        let userLines = errors.compactMap { shader.lineMap.userLine(forLine: $0.line) }
        #expect(userLines.contains(1))
    }
}
