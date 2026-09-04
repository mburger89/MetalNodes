import Testing
import Metal
import MetalNodesCore
@testable import MetalNodesRender

@Suite struct ShaderCompilerTests {
    static let device = MTLCreateSystemDefaultDevice()

    private func compiler() throws -> ShaderCompiler {
        let d = try #require(Self.device, "No Metal device — these tests need a GPU")
        return try ShaderCompiler(device: d)
    }

    @Test func sampleDocumentCompiles() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        guard case .success(let p) = await c.compile(shader, generation: 1) else {
            Issue.record("expected success"); return
        }
        #expect(p.generation == 1)
        #expect(p.shader == shader)
    }

    @Test func everyBuiltinNodeCompilesAsAOneNodeGraph() async throws {
        let c = try compiler()
        for def in NodeRegistry.builtin.all where def.id != "output.fragment" {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def.id))
            let out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            if let first = def.outputs.first {
                doc.root.connect(SocketRef(n.id, first.name), to: SocketRef(out.id, "color"))
            }
            let shader = try ShaderGenerator.generate(doc)
            let result = await c.compile(shader, generation: 1)
            if case .failure(let msg, _, _) = result { Issue.record("\(def.id) failed: \(msg)\n\(shader.source)") }
        }
    }

    @Test func everyMathVariantCompiles() async throws {
        let c = try compiler()
        let def = NodeRegistry.builtin["math.math"]!
        guard case .variants(_, let table) = def.body else { return }
        for op in table.keys.sorted() {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase(op)])
            let out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            doc.root.connect(SocketRef(n.id, "out"), to: SocketRef(out.id, "color"))
            if case .failure(let msg, _, _) = await c.compile(try ShaderGenerator.generate(doc), generation: 1) {
                Issue.record("math.\(op) failed: \(msg)")
            }
        }
    }

    @Test func olderGenerationIsSuperseded() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 2)
        guard case .superseded(let g) = await c.compile(shader, generation: 1) else {
            Issue.record("expected superseded"); return
        }
        #expect(g == 1)
    }

    @Test func identicalSourceHitsTheCache() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 1)
        _ = await c.compile(shader, generation: 2)
        #expect(await c.cacheCount == 1)
    }

    @Test func brokenSourceReportsFailureWithLine() async throws {
        let c = try compiler()
        var shader = try ShaderGenerator.generate(ShaderDocument.sample())
        shader = GeneratedShader(source: shader.source.replacingOccurrences(of: "return", with: "retrun"),
                                 layout: shader.layout, lineMap: shader.lineMap, resolved: shader.resolved,
                                 fragmentFunctionName: shader.fragmentFunctionName, target: shader.target)
        guard case .failure(_, let lines, _) = await c.compile(shader, generation: 1) else {
            Issue.record("expected failure"); return
        }
        #expect(!lines.isEmpty)
        #expect(lines.first!.line > 1)
    }

    @Test func parsesClangStyleLines() {
        let msg = "program_source:42:9: error: use of undeclared identifier 'retrun'\nprogram_source:50:1: warning: unused"
        let lines = ShaderCompiler.parseLines(msg)
        #expect(lines == [CompileLine(line: 42, message: "use of undeclared identifier 'retrun'"),
                          CompileLine(line: 50, message: "unused")])
    }
}
