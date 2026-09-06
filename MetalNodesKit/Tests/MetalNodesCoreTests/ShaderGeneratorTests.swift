import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct ShaderGeneratorTests {
    /// UV → Separate → Combine(x, y, 0.5-default) → Output. Deterministic IDs so the golden is stable.
    private func smallDocument() -> (ShaderDocument, uv: NodeID, sep: NodeID, comb: NodeID, out: NodeID) {
        func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
        let uv = NodeInstance(id: id(1), kind: .builtin("input.uv"))
        let sep = NodeInstance(id: id(2), kind: .builtin("vector.separate"))
        let comb = NodeInstance(id: id(3), kind: .builtin("vector.combine"), params: ["z": .float(0.5)])
        let out = NodeInstance(id: id(4), kind: .builtin("output.fragment"))
        var g = Graph()
        for n in [uv, sep, comb, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(sep.id, "v"))
        g.connect(SocketRef(sep.id, "x"), to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"), to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(comb.id, "out"), to: SocketRef(out.id, "color"))
        var d = ShaderDocument(); d.root = g
        return (d, uv.id, sep.id, comb.id, out.id)
    }

    @Test func goldenSource() throws {
        let (doc, _, _, _, _) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
        let expected = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 resolution;
            float2 mouse;
            float time;
            float p0;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        fragment float4 shaderMain(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]]) {
            float2 v0;
            v0 = in.uv;
            float v1;
            float v2;
            float v3;
            v1 = float3(v0, 0.0).x;
            v2 = float3(v0, 0.0).y;
            v3 = float3(v0, 0.0).z;
            float3 v4;
            v4 = float3(v1, v2, u.p0);
            return float4(v4, 1.0);
        }

        """
        #expect(shader.source == expected)
        #expect(shader.fragmentFunctionName == "shaderMain")
    }

    @Test func lineMapPointsAtNodes() throws {
        let (doc, uv, sep, comb, out) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
        let lines = shader.source.components(separatedBy: "\n")
        func line(containing s: String) -> Int { lines.firstIndex { $0.contains(s) }! + 1 }
        #expect(shader.lineMap.node(forLine: line(containing: "v0 = in.uv;")) == uv)
        #expect(shader.lineMap.node(forLine: line(containing: "v2 = float3(v0, 0.0).y;")) == sep)
        #expect(shader.lineMap.node(forLine: line(containing: "v4 = float3(v1, v2, u.p0);")) == comb)
        #expect(shader.lineMap.node(forLine: line(containing: "return float4(v4, 1.0);")) == out)
        #expect(shader.lineMap.node(forLine: 1) == nil)
    }

    @Test func layoutOnlyContainsReferencedSlots() throws {
        let (doc, _, _, comb, _) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
        let user = shader.layout.fields.compactMap(\.path)
        #expect(user == [ParamPath(node: comb, param: "z")])
    }

    @Test func unaryMathAllocatesNoSlotForUnusedInput() throws {
        var doc = ShaderDocument()
        let m = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("sine")])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[m.id] = m; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(m.id, "out"), to: SocketRef(out.id, "color"))
        let shader = try ShaderGenerator.generate(doc)
        #expect(shader.layout.fields.compactMap(\.path).map(\.param) == ["a"])
        #expect(shader.source.contains("v0 = sin(u.p0);"))
    }

    @Test func stdlibFunctionsAreIncludedOnceInDependencyOrder() throws {
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        let src = shader.source
        #expect(src.components(separatedBy: "float mn_hash21(").count == 2)
        #expect(src.components(separatedBy: "float mn_valueNoise(").count == 2)
        #expect(src.range(of: "mn_hash21(float2 p)")!.lowerBound < src.range(of: "mn_valueNoise(float2 p)")!.lowerBound)
    }

    @Test func sampleDocumentUsesTypePlaceholderAndVariants() throws {
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        #expect(shader.source.contains("mix("))
        #expect(shader.source.contains("sin("))
        #expect(shader.layout.fields.filter { $0.path != nil }.count == 3)   // speed.value, noise.scale, tint.value
        #expect(shader.layout.fields.first?.mslType == "float4")            // tint sorted first (16-byte)
    }

    @Test func boolUniformIsCastOnRead() throws {
        let def = NodeDef(id: "t.flag", title: "Flag", category: .utility,
                          inputs: [SocketDecl(name: "on", type: .concrete(.bool), default: .value(.bool(true)))],
                          outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                          body: .template("{out.out} = {in.on} ? 1.0 : 0.0;"))
        let reg = try NodeRegistry(BuiltinNodes.all + [def])
        var doc = ShaderDocument()
        let f = NodeInstance(kind: .builtin("t.flag")), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[f.id] = f; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(out.id, "color"))
        let shader = try ShaderGenerator.generate(doc, registry: reg)
        #expect(shader.source.contains("v0 = bool(u.p0) ? 1.0 : 0.0;"))
    }

    @Test func invalidGraphThrowsDiagnostics() {
        let doc = ShaderDocument()   // no output node
        let error = #expect(throws: GenerationError.self) { try ShaderGenerator.generate(doc) }
        guard let error, case .invalid(let diagnostics) = error else { Issue.record("no diagnostics"); return }
        #expect(diagnostics.contains { $0.severity == .error })
    }

    @Test func unknownEnumCaseThrowsRatherThanCrashing() {
        var doc = ShaderDocument()
        let m = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("bogus")])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[m.id] = m; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(m.id, "out"), to: SocketRef(out.id, "color"))
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(doc) }
    }

    @Test func generationIsDeterministic() throws {
        let a = try ShaderGenerator.generate(ShaderDocument.sample())
        let b = try ShaderGenerator.generate(ShaderDocument.sample())
        // sample() makes fresh IDs each call, so compare shape rather than bytes:
        #expect(a.source.count == b.source.count)
        #expect(a.layout.fields.map(\.mslType) == b.layout.fields.map(\.mslType))
    }
}
