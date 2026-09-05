import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct LibraryM3Tests {
    let reg = NodeRegistry.builtin

    /// Every node as a one-node graph (first output → Fragment Output) generates without diagnostics.
    @Test func everyNodeGeneratesAsAOneNodeGraph() throws {
        for def in reg.all where def.id != "output.fragment" {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            if let first = def.outputs.first { doc.root.connect(SocketRef(n.id, first.name), to: SocketRef(out.id, "color")) }
            let s = try ShaderGenerator.generate(doc, registry: reg)
            #expect(!s.source.contains("/* ?"), "\(def.id)")
            #expect(!s.source.contains("/* unconnected */"), "\(def.id)")
        }
    }

    @Test func inputConstantsCoverEveryUniformableType() {
        #expect(reg["input.float2"]?.outputs.first?.type == .concrete(.float2))
        #expect(reg["input.float3"]?.outputs.first?.type == .concrete(.float3))
        #expect(reg["input.int"]?.outputs.first?.type == .concrete(.int))
        #expect(reg["input.bool"]?.outputs.first?.type == .concrete(.bool))
        #expect(reg["input.mouse"]?.outputs.first?.name == "position")
    }

    @Test func mouseReadsTheSystemValue() throws {
        let m = NodeInstance(kind: .builtin("input.mouse")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[m.id] = m; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(m.id, "position"), to: SocketRef(out.id, "color"))
        #expect(try ShaderGenerator.generate(d).source.contains("v0 = u.mouse;"))
        d.settings.target = .stitchable(.colorEffect)
        #expect(try ShaderGenerator.generate(d, target: d.settings.target).exportSource!.contains("v0 = mouse;"))
    }

    @Test func mapRangeCastsScalarEdgesToTheGenericType() throws {
        let v = NodeInstance(kind: .builtin("vector.combine")), mr = NodeInstance(kind: .builtin("math.maprange"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [v, mr, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(v.id, "out"), to: SocketRef(mr.id, "value"))
        d.root.connect(SocketRef(mr.id, "out"), to: SocketRef(out.id, "color"))
        let src = try ShaderGenerator.generate(d).source
        #expect(src.contains("float3(u.p"))          // edges are cast to float3
    }

    @Test func rotate2dGoesThroughTheStdlib() throws {
        let def = try #require(reg["vector.rotate2d"])
        #expect(def.requires == ["rotate2d"])
        #expect(MSLStdlib.functions["rotate2d"]?.source.contains("float2 mn_rotate2d(float2 v, float angle, float2 center)") == true)
    }
}
