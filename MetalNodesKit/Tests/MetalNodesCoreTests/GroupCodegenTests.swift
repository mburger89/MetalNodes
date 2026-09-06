import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GroupCodegenTests {
    let reg = NodeRegistry.builtin

    /// Deterministic ids so the golden is stable.
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func gid(_ n: Int) -> GroupID { GroupID(raw: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))!) }

    /// Definition "Twice": x (float, default 1) → Math add(x, x) → out. Root: Float(0.25) → Twice → Output.
    /// Math's `b` is wired too, so the only slot is the root Float's value.
    private func twice() -> ShaderDocument {
        var def = GroupDefinition(id: gid(1), name: "Twice")
        let gin = NodeInstance(id: id(10), kind: .groupInput), gout = NodeInstance(id: id(11), kind: .groupOutput, position: CGPoint(x: 600, y: 0))
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

    @Test func oneLevelGroupGolden() throws {
        let s = try ShaderGenerator.generate(twice(), registry: reg)
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

        struct G_10000000_Out {
            float out;
        };

        G_10000000_Out mn_g_Twice_10000000(float2 uv, float time, float2 size, float2 mouse, float in_x) {
            float v0;
            v0 = in_x;
            float v1;
            v1 = v0 + v0;
            G_10000000_Out out;
            out.out = v1;
            return out;
        }

        fragment float4 shaderMain(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]]) {
            float v0;
            v0 = u.p0;
            G_10000000_Out r1 = mn_g_Twice_10000000(in.uv, u.time, u.resolution, u.mouse, v0);
            float v2;
            v2 = r1.out;
            return float4(float3(v2), 1.0);
        }

        """
        #expect(s.source == expected)
    }

    @Test func sharedAndPerInstanceSlots() throws {
        // Two instances of a definition whose internal Float param is unwired (shared slot) and
        // whose exposed input `x` is unwired on both instances (two per-instance slots).
        var def = GroupDefinition.make(name: "G")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let inner = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("multiply")])   // b unwired → shared
        def.graph.nodes[inner.id] = inner
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(inner.id, "a"))
        def.graph.connect(SocketRef(inner.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let i1 = NodeInstance(kind: .group(def.id), params: ["x": .float(2)]), i2 = NodeInstance(kind: .group(def.id))
        let add = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")]), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [i1, i2, add, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(i1.id, "out"), to: SocketRef(add.id, "a"))
        doc.root.connect(SocketRef(i2.id, "out"), to: SocketRef(add.id, "b"))
        doc.root.connect(SocketRef(add.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        let paths = s.layout.fields.compactMap(\.path)
        #expect(paths.count == 3)
        #expect(paths.contains(ParamPath(node: i1.id, param: "x")) && paths.contains(ParamPath(node: i2.id, param: "x")))
        #expect(paths.contains(ParamPath(node: inner.id, param: "b")))
        #expect(s.source.contains("float in_x, float u_"))                // the shared slot is a function parameter
        #expect(s.source.components(separatedBy: "mn_g_G_").count == 4)   // one definition + two calls
    }

    @Test func nestedGroupsCallInnerFunctionsAndPropagateUniforms() throws {
        // Outer contains Inner; Inner has an unwired internal Float → its slot must appear in Outer's parameter list.
        var inner = GroupDefinition.make(name: "Inner")
        inner.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let f = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(3)])
        inner.graph.nodes[f.id] = f
        inner.graph.connect(SocketRef(f.id, "out"), to: SocketRef(inner.outputNode!, "v"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let ii = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[ii.id] = ii
        outer.graph.connect(SocketRef(ii.id, "v"), to: SocketRef(outer.outputNode!, "v"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let io = NodeInstance(kind: .group(outer.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[io.id] = io; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(io.id, "v"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        let innerFn = s.source.range(of: "mn_g_Inner_")!.lowerBound, outerFn = s.source.range(of: "mn_g_Outer_")!.lowerBound
        #expect(innerFn < outerFn)                                        // inner-most first
        let pName = GroupCodegen.parameterName(for: ParamPath(node: f.id, param: "value"))
        #expect(s.source.contains("mn_g_Outer_\(GroupCodegen.hex8(outer.id))(float2 uv, float time, float2 size, float2 mouse, float \(pName))"))
        #expect(s.source.contains("u.p0);"))                              // the root call passes the slot
        #expect(s.layout.fields.compactMap(\.path) == [ParamPath(node: f.id, param: "value")])
    }

    @Test func groupCallsWorkUnderAStitchableTarget() throws {
        var doc = twice(); doc.settings.target = .stitchable(.colorEffect); doc.settings.exportName = "g"
        let s = try ShaderGenerator.generate(doc, target: doc.settings.target, registry: reg)
        #expect(s.exportSource!.contains("mn_g_Twice_10000000(uv, time, size, mouse, v0)"))
        #expect(s.exportSource!.range(of: "G_10000000_Out mn_g_Twice")!.lowerBound < s.exportSource!.range(of: "[[stitchable]]")!.lowerBound)
    }

    @Test func requiredStdlibOfInnerNodesIsIncludedOnce() throws {
        var def = GroupDefinition.make(name: "N")
        def.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let noise = NodeInstance(kind: .builtin("noise.value"))
        def.graph.nodes[noise.id] = noise
        def.graph.connect(SocketRef(noise.id, "out"), to: SocketRef(def.outputNode!, "v"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let i1 = NodeInstance(kind: .group(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[i1.id] = i1; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(i1.id, "v"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        #expect(s.source.components(separatedBy: "float mn_valueNoise(").count == 2)
        #expect(s.source.range(of: "float mn_valueNoise(")!.lowerBound < s.source.range(of: "mn_g_N_")!.lowerBound)
    }

    @Test func sampleWithGroupGenerates() throws {
        let s = try ShaderGenerator.generate(ShaderDocument.sampleWithGroup(), registry: reg)
        #expect(s.source.contains("mn_g_"))
    }
}
