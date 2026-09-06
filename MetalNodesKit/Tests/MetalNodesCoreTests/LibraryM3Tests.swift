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

    @Test func sdfAndNoiseNodesExistWithFloatOutputs() {
        for id in ["sdf.circle", "sdf.box", "sdf.union", "sdf.subtract", "noise.perlin", "noise.simplex", "noise.voronoi", "noise.fbm"] {
            #expect(reg[id]?.outputs.first?.type == .concrete(.float), "\(id)")
        }
        #expect(reg["sdf.circle"]?.category == .sdf)
    }

    @Test func fbmOctavesIsAnIntUniformReadInsideTheLoop() throws {
        let f = NodeInstance(kind: .builtin("noise.fbm")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[f.id] = f; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(f.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.layout.field(for: ParamPath(node: f.id, param: "octaves"))?.type == .int)
        #expect(s.source.contains("mn_fbm(in.uv * u.p"))
        #expect(s.source.contains("float mn_fbm(float2 p, int octaves)"))
        #expect(MSLStdlib.resolve(["fbm"]).map(\.name) == ["hash21", "valueNoise", "fbm"])
    }

    @Test func stdlibDependenciesResolveForEveryNoise() {
        #expect(MSLStdlib.resolve(["perlin"]).map(\.name) == ["hash22", "perlin"])
        #expect(MSLStdlib.resolve(["voronoi"]).map(\.name) == ["hash22", "voronoi"])
        #expect(MSLStdlib.resolve(["simplex"]).map(\.name) == ["mod289_2", "mod289_3", "permute3", "simplex"])
    }

    @Test func registryHasTheFullV1Set() {
        #expect(reg.all.count == 40)
        // .group has no builtin defs — it's only ever a group instance's category, never a NodeDef's.
        for c in NodeCategory.allCases where c != .group { #expect(reg.all.contains { $0.category == c }, "\(c)") }
    }

    @Test func colorRampOnlyClaimsSlotsForItsChosenStopCount() throws {
        func slots(_ stops: String) throws -> Int {
            let r = NodeInstance(kind: .builtin("color.ramp"), params: ["stops": .enumCase(stops)])
            let out = NodeInstance(kind: .builtin("output.fragment"))
            var d = ShaderDocument(); d.root.nodes[r.id] = r; d.root.nodes[out.id] = out
            d.root.connect(SocketRef(r.id, "out"), to: SocketRef(out.id, "color"))
            return try ShaderGenerator.generate(d).layout.fields.filter { $0.path?.instancePath.first == r.id }.count
        }
        #expect(try slots("2") == 3)     // fac, col0, col1
        #expect(try slots("3") == 5)     // fac, col0, pos1, col1, col2
        #expect(try slots("4") == 7)     // fac, col0, pos1, col1, pos2, col2, col3
    }

    @Test func rampStopControlsAreHiddenFromTheBody() throws {
        let def = try #require(reg["color.ramp"])
        #expect(def.params.filter(\.showsInBody).map(\.name) == ["stops"])
        #expect(def.params.count == 7)
    }

    @Test func rerouteIsADotAndKeepsAnExactType() throws {
        let def = try #require(reg["utility.reroute"])
        #expect(def.style == .dot)
        let c = NodeInstance(kind: .builtin("input.color")), r = NodeInstance(kind: .builtin("utility.reroute"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [c, r, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(c.id, "out"), to: SocketRef(r.id, "in"))
        d.root.connect(SocketRef(r.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.resolved[r.id]?.outputTypes["out"] == .color)
    }

    @Test func compareProducesBoolAndSwitchSelects() throws {
        let cmp = NodeInstance(kind: .builtin("utility.compare"), params: ["op": .enumCase("greater")])
        let sw = NodeInstance(kind: .builtin("utility.switch")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [cmp, sw, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(cmp.id, "out"), to: SocketRef(sw.id, "cond"))
        d.root.connect(SocketRef(sw.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.resolved[cmp.id]?.outputTypes["out"] == .bool)
        #expect(s.source.contains(" > "))
        #expect(s.source.contains(" ? "))
    }
}
