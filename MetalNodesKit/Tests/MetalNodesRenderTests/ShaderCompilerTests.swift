import Testing
import Metal
import Foundation
import CoreGraphics
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

    @Test func everyVariantOfEveryVariantsNodeCompiles() async throws {
        let c = try compiler()
        for def in NodeRegistry.builtin.all {
            guard case .variants(let param, let table) = def.body else { continue }
            for op in table.keys.sorted() {
                var doc = ShaderDocument()
                let n = NodeInstance(kind: .builtin(def.id), params: [param: .enumCase(op)])
                let out = NodeInstance(kind: .builtin("output.fragment"))
                doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
                if let first = def.outputs.first {
                    doc.root.connect(SocketRef(n.id, first.name), to: SocketRef(out.id, "color"))
                }
                let shader = try ShaderGenerator.generate(doc)
                if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) {
                    Issue.record("\(def.id).\(op) failed: \(msg)\n\(shader.source)")
                }
            }
        }
    }

    @Test func everyViewableTypeCompilesAsAViewerProgram() async throws {
        let c = try compiler()
        for (def, socket) in [("input.float", "out"), ("input.float2", "out"), ("input.float3", "out"), ("input.color", "out"),
                              ("input.int", "out"), ("input.bool", "out")] {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def)), out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            let shader = try ShaderGenerator.generate(doc, viewer: SocketRef(n.id, socket))
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(def) viewer failed: \(msg)\n\(shader.source)") }
        }
    }

    @Test func everyStitchableKindPreviewCompiles() async throws {
        let c = try compiler()
        for kind in StitchableKind.allCases {
            var doc = ShaderDocument.sample()
            doc.settings.target = .stitchable(kind)
            let shader = try ShaderGenerator.generate(doc, target: doc.settings.target)
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(kind) preview failed: \(msg)\n\(shader.source)") }
        }
    }

    @Test func groupProgramsCompile() async throws {
        let c = try compiler()
        var doc = ShaderDocument.sampleWithGroup()
        for target in OutputTarget.all {
            doc.settings.target = target
            let shader = try ShaderGenerator.generate(doc, target: target)
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(target.title): \(msg)\n\(shader.source)") }
        }
    }

    /// Root: Float → Outer → Output; Outer: GroupInput.x → Inner → GroupOutput; Inner: GroupInput.x → Math(add) → GroupOutput.
    private func nestedGroups() -> (doc: ShaderDocument, outerInst: NodeID, innerInst: NodeID, math: NodeID, inner: GroupID) {
        var inner = GroupDefinition.make(name: "Inner")
        inner.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        inner.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        inner.graph.nodes[math.id] = math
        inner.graph.connect(SocketRef(inner.inputNode!, "x"), to: SocketRef(math.id, "a"))
        inner.graph.connect(SocketRef(math.id, "out"), to: SocketRef(inner.outputNode!, "out"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.inputs = inner.inputs; outer.outputs = inner.outputs
        let ii = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[ii.id] = ii
        outer.graph.connect(SocketRef(outer.inputNode!, "x"), to: SocketRef(ii.id, "x"))
        outer.graph.connect(SocketRef(ii.id, "out"), to: SocketRef(outer.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let f = NodeInstance(kind: .builtin("input.float")), io = NodeInstance(kind: .group(outer.id))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [f, io, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(io.id, "x"))
        doc.root.connect(SocketRef(io.id, "out"), to: SocketRef(out.id, "color"))
        return (doc, io.id, ii.id, math.id, inner.id)
    }

    @Test func groupViewerProgramsCompile() async throws {
        let c = try compiler()
        let (doc, io, ii, math, inner) = nestedGroups()
        let dived = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [io, ii])
        if case .failure(let msg, _, _) = await c.compile(dived, generation: 1) { Issue.record("dived viewer: \(msg)\n\(dived.source)") }
        let palette = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerDefinition: inner)
        if case .failure(let msg, _, _) = await c.compile(palette, generation: 1) { Issue.record("palette viewer: \(msg)\n\(palette.source)") }
        // Edit from the palette, then dive: anchored inside the opened definition.
        let outer = doc.definitions.values.first { $0.name == "Outer" }!.id
        let anchored = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [ii], viewerDefinition: outer)
        if case .failure(let msg, _, _) = await c.compile(anchored, generation: 1) { Issue.record("anchored viewer: \(msg)\n\(anchored.source)") }
    }

    /// Generations belong to each `EditorModel`, not to the shared compiler: an older number is not
    /// stale, it is another document's counter, and must still yield a pipeline.
    @Test func olderGenerationStillSucceeds() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 2)
        guard case .success(let p) = await c.compile(shader, generation: 1) else {
            Issue.record("expected success"); return
        }
        #expect(p.generation == 1)
    }

    /// A second document window counts from 0 while the first has climbed: both must compile.
    @Test func compilesForEveryClientRegardlessOfGeneration() async throws {
        let c = try compiler()
        let first = try ShaderGenerator.generate(ShaderDocument.sample())
        let second = variant(first, tag: 77)
        guard case .success(let a) = await c.compile(first, generation: 5) else {
            Issue.record("expected success at generation 5"); return
        }
        guard case .success(let b) = await c.compile(second, generation: 1) else {
            Issue.record("expected success at generation 1"); return
        }
        #expect(a.generation == 5)
        #expect(b.generation == 1)
        #expect(a.shader.source != b.shader.source)
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
        #expect(lines.first!.severity == .error)
    }

    private func variant(_ shader: GeneratedShader, tag: Int) -> GeneratedShader {
        GeneratedShader(source: shader.source + "\n// variant \(tag)\n", layout: shader.layout, lineMap: shader.lineMap,
                        resolved: shader.resolved, fragmentFunctionName: shader.fragmentFunctionName, target: shader.target)
    }

    @Test func parsesClangStyleLinesWithSeverity() {
        let msg = """
        program_source:42:9: error: use of undeclared identifier 'retrun'
        program_source:50:1: warning: unused variable 'v3'
        program_source:12:3: note: expanded from macro
        """
        #expect(ShaderCompiler.parseLines(msg) == [
            CompileLine(line: 42, severity: .error, message: "use of undeclared identifier 'retrun'"),
            CompileLine(line: 50, severity: .warning, message: "unused variable 'v3'"),
            CompileLine(line: 12, severity: .note, message: "expanded from macro"),
        ])
    }

    @Test func lruEvictsTheLeastRecentlyUsedPipeline() async throws {
        let d = try #require(Self.device)
        let c = try ShaderCompiler(device: d, cacheLimit: 2)
        let base = try ShaderGenerator.generate(ShaderDocument.sample())
        let a = variant(base, tag: 1), b = variant(base, tag: 2), x = variant(base, tag: 3)
        _ = await c.compile(a, generation: 1)
        _ = await c.compile(b, generation: 1)
        _ = await c.compile(a, generation: 1)          // touch a → b is now least recent
        _ = await c.compile(x, generation: 1)          // evicts b
        #expect(await c.cacheCount == 2)
        #expect(await c.isCached(a))
        #expect(await c.isCached(x))
        #expect(await c.isCached(b) == false)
    }

    @Test func fastMathIsPartOfTheCacheKey() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 1, fastMath: true)
        _ = await c.compile(shader, generation: 1, fastMath: false)
        #expect(await c.cacheCount == 2)
        #expect(await c.isCached(shader, fastMath: false))
    }

    /// A failure is reported to whoever asked for it, whatever number they gave it: the compiler
    /// cannot tell a stale generation from another document's.
    @Test func failureIsReportedAtAnyGeneration() async throws {
        let c = try compiler()
        let good = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(good, generation: 2)
        var broken = variant(good, tag: 9)
        broken = GeneratedShader(source: broken.source.replacingOccurrences(of: "return", with: "retrun"),
                                 layout: broken.layout, lineMap: broken.lineMap, resolved: broken.resolved,
                                 fragmentFunctionName: broken.fragmentFunctionName, target: broken.target)
        guard case .failure(_, let lines, let g) = await c.compile(broken, generation: 1) else {
            Issue.record("expected failure for a broken compile"); return
        }
        #expect(g == 1)
        #expect(!lines.isEmpty)
    }

    // MARK: - Textured documents (Task 2: renderer binds texture slots)

    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "40000000-0000-0000-0000-%012d", n))!) }

    /// UV → Texture Sample(asset) → Output, mirroring TextureCodegenTests.doc().
    private func texturedFragmentDoc() -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.assets[aid(1)] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let uv = NodeInstance(kind: .builtin("input.uv"))
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [uv, sample, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(sample.id, "uv"))
        d.root.connect(SocketRef(sample.id, "color"), to: SocketRef(out.id, "color"))
        return d
    }

    /// A one-node group definition sampling an asset, instantiated once in the root.
    private func texturedGroupDoc() -> ShaderDocument {
        var def = GroupDefinition.make(name: "Tex")
        def.outputs = [SocketDecl(name: "color", type: .concrete(.color))]
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        def.graph.nodes[sample.id] = sample
        def.graph.connect(SocketRef(sample.id, "color"), to: SocketRef(def.outputNode!, "color"))
        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[inst.id] = inst; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(inst.id, "color"), to: SocketRef(out.id, "color"))
        return d
    }

    @Test func texturedFragmentProgramCompiles() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(texturedFragmentDoc())
        #expect(shader.textures == [TextureSlot(index: 0, asset: aid(1))])
        guard case .success(let p) = await c.compile(shader, generation: 1) else {
            Issue.record("expected success"); return
        }
        #expect(p.shader.textures == [TextureSlot(index: 0, asset: aid(1))])
    }

    @Test func texturedGroupProgramCompiles() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(texturedGroupDoc())
        #expect(shader.textures == [TextureSlot(index: 0, asset: aid(2))])
        if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) {
            Issue.record("group texture failed: \(msg)\n\(shader.source)")
        }
    }

    @Test func layerEffectTargetWithATextureSampleCompiles() async throws {
        let c = try compiler()
        var d = texturedFragmentDoc()
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"
        let shader = try ShaderGenerator.generate(d, target: d.settings.target)
        #expect(shader.textures == [TextureSlot(index: 0, asset: aid(1))])
        if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) {
            Issue.record("layer effect texture failed: \(msg)\n\(shader.source)")
        }
    }

    /// Viewer-shape compile: the Texture Sample's own `color` socket, viewed directly (spec §19.3),
    /// still binds the same one texture slot the fragment program does.
    @Test func viewerOnATextureSampleCompiles() async throws {
        let c = try compiler()
        let doc = texturedFragmentDoc()
        let sample = doc.root.nodes.values.first { $0.kind == .builtin("texture.sample") }!
        let shader = try ShaderGenerator.generate(doc, target: .fragment, viewer: SocketRef(sample.id, "color"), registry: .builtin)
        #expect(shader.textures == [TextureSlot(index: 0, asset: aid(1))])
        if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) {
            Issue.record("viewer texture failed: \(msg)\n\(shader.source)")
        }
    }
}
