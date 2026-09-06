import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// Spec §9.4/§21.8: the program's line map reaches inside group-function bodies, so an error on a
/// line of `mn_g_…` outlines the node in the definition that produced it.
@Suite struct LineMapGroupTests {
    let reg = NodeRegistry.builtin

    /// Deterministic ids so the mapped lines can be named in the expectations.
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func gid(_ n: Int) -> GroupID { GroupID(raw: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))!) }

    /// The `GroupCodegenTests.twice()` document: definition "Twice" is x → Math add(x, x) → out,
    /// the root is Float(0.25) → Twice → Fragment Output.
    private func twice() -> ShaderDocument {
        var def = GroupDefinition(id: gid(1), name: "Twice")
        let gin = NodeInstance(id: id(10), kind: .groupInput)
        let gout = NodeInstance(id: id(11), kind: .groupOutput, position: CGPoint(x: 600, y: 0))
        def.graph.nodes[gin.id] = gin; def.graph.nodes[gout.id] = gout
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(id: id(12), kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        def.graph.nodes[math.id] = math
        def.graph.connect(SocketRef(gin.id, "x"), to: SocketRef(math.id, "a"))
        def.graph.connect(SocketRef(gin.id, "x"), to: SocketRef(math.id, "b"))
        def.graph.connect(SocketRef(math.id, "out"), to: SocketRef(gout.id, "out"))
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let f = NodeInstance(id: id(1), kind: .builtin("input.float"), params: ["value": .float(0.25)])
        let inst = NodeInstance(id: id(2), kind: .group(def.id))
        let out = NodeInstance(id: id(3), kind: .builtin("output.fragment"))
        for n in [f, inst, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst.id, "x"))
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        return doc
    }

    /// The source lines the map attributes to `node`, trimmed, in program order.
    private func mappedLines(_ s: GeneratedShader, _ node: NodeID) -> [String] {
        let lines = s.source.components(separatedBy: "\n")
        return s.lineMap.lines(for: node).flatMap { Array($0) }.sorted()
            .map { lines[$0 - 1].trimmingCharacters(in: .whitespaces) }
    }

    @Test func groupFunctionBodyLinesMapToTheNodesInsideTheDefinition() throws {
        let s = try ShaderGenerator.generate(twice(), registry: reg)
        // The Math inside "Twice" owns its declaration and its statement, inside `mn_g_Twice_…`.
        #expect(mappedLines(s, id(12)) == ["float v1;", "v1 = v0 + v0;"])
        // …and the Group Input owns the lines that read the exposed socket.
        #expect(mappedLines(s, id(10)) == ["float v0;", "v0 = in_x;"])
    }

    @Test func rootNodeLinesAreUnchanged() throws {
        let s = try ShaderGenerator.generate(twice(), registry: reg)
        #expect(mappedLines(s, id(1)) == ["float v0;", "v0 = u.p0;"])
        #expect(mappedLines(s, id(2)) == ["G_10000000_Out r1 = mn_g_Twice_10000000(in.uv, u.time, u.resolution, u.mouse, v0);",
                                          "float v2;", "v2 = r1.out;"])
        #expect(mappedLines(s, id(3)) == ["return float4(float3(v2), 1.0);"])
    }

    @Test func linesNoNodeProducedStayUnowned() throws {
        let s = try ShaderGenerator.generate(twice(), registry: reg)
        let lines = s.source.components(separatedBy: "\n")
        // The result struct, the signature and the epilogue of the group function belong to no node.
        for text in ["struct G_10000000_Out {", "    float out;", "};",
                     "G_10000000_Out mn_g_Twice_10000000(float2 uv, float time, float2 size, float2 mouse, float in_x) {",
                     "    G_10000000_Out out;", "    out.out = v1;", "    return out;"] {
            let line = try #require(lines.firstIndex(of: text).map { $0 + 1 })
            #expect(s.lineMap.node(forLine: line) == nil)
        }
    }

    @Test func viewerThroughAnInstanceMapsTheViewedNodeInsideTheVariant() throws {
        let s = try ShaderGenerator.generate(twice(), viewer: SocketRef(id(12), "out"), viewerPath: [id(2)], registry: reg)
        // Both the normal function and the `_view` variant carry the Math's two lines, and the
        // viewer's own wrap statement in `shaderMain` stays attributed to the viewed node.
        #expect(mappedLines(s, id(12)) == [
            "float v1;", "v1 = v0 + v0;", "float v1;", "v1 = v0 + v0;",
            "return float4(float3(saturate((v2 - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);",
        ])
        #expect(s.source.contains("_view("))
    }

    @Test func stitchablePreviewMapsGroupFunctionBodies() throws {
        var doc = twice(); doc.settings.target = .stitchable(.colorEffect); doc.settings.exportName = "g"
        let s = try ShaderGenerator.generate(doc, target: doc.settings.target, registry: reg)
        #expect(mappedLines(s, id(12)) == ["float v1;", "v1 = v0 + v0;"])
    }
}
