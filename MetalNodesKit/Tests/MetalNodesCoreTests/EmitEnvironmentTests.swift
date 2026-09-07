import Testing
@testable import MetalNodesCore

@Suite struct EmitEnvironmentTests {
    private func field(_ name: String, _ type: SocketType) -> UniformField {
        UniformField(name: name, mslType: type.uniformStorageName ?? type.mslName, offset: 0, size: type.byteSize ?? 0, type: type, path: nil)
    }

    @Test func fragmentEnvironmentReadsTheUniformStruct() {
        let env = EmitEnvironment.fragment
        #expect(env.uniform(field("p0", .float)) == "u.p0")
        #expect(env.uniform(field("p3", .int)) == "u.p3")
        #expect(env.uniform(field("p4", .bool)) == "bool(u.p4)")
        #expect(env.sys["uv"] == "in.uv")
        #expect(env.sys["time"] == "u.time")
        #expect(env.sys["resolution"] == "u.resolution")
        #expect(env.sys["mouse"] == "u.mouse")
    }

    @Test func stitchableEnvironmentReadsArgumentsAndCastsScalars() {
        let env = EmitEnvironment.stitchableFunction
        #expect(env.uniform(field("p0", .float)) == "p0")
        #expect(env.uniform(field("p3", .int)) == "int(p3)")
        #expect(env.uniform(field("p4", .bool)) == "bool(p4)")
        // SwiftUI passes `.color(_:)` as a premultiplied half4, so a colour argument is widened on read.
        #expect(env.uniform(field("p5", .color)) == "float4(p5)")
        #expect(env.uniform(field("p6", .float4)) == "p6")
        #expect(env.sys["uv"] == "uv")
        #expect(env.sys["resolution"] == "size")
        #expect(env.sys["mouse"] == "mouse")
    }

    @Test func sysPlaceholdersAreSubstitutedFromTheEnvironment() {
        let ctx = EmitContext(inputs: [:], outputs: ["o": "v0"], params: [:], enums: [:], types: [:],
                              sys: ["uv": "in.uv", "time": "u.time"])
        #expect(Emitter.substitute("{out.o} = {sys.uv} * {sys.time};", ctx) == ["v0 = in.uv * u.time;"])
    }

    @Test func layoutTakesItsReservedList() {
        let l = UniformLayoutBuilder.build([], reserved: UniformLayoutBuilder.viewerReserved)
        #expect(l.hasReserved("viewerMin"))
        #expect(l.hasReserved("viewerMax"))
        #expect(!UniformLayoutBuilder.build([]).hasReserved("viewerMin"))
        #expect(l.reserved("viewerMax").offset == 24)     // float2, float2, float, float, float
    }

    @Test func sourceBuilderTracksOwnersAcrossMultiLineChunks() {
        let a = NodeID(), b = NodeID()
        var s = SourceBuilder()
        s.add("header")                      // line 1
        s.add("x;\ny;", owner: a)            // lines 2–3
        s.add("z;", owner: a)                // line 4, merges
        s.add("w;", owner: b)                // line 5
        #expect(s.text == "header\nx;\ny;\nz;\nw;\n")
        #expect(s.map.lines(for: a) == [2...4])
        #expect(s.map.node(forLine: 5) == b)
    }
}

@Suite struct RealityKitEnvironmentTests {
    @Test func surfaceAndGeometrySpellTheirAccessors() {
        let s = EmitEnvironment.realityKitSurface.sys
        #expect(s["uv"] == "params.geometry().uv0()")
        #expect(s["time"] == "params.uniforms().time()")
        #expect(s["worldPosition"] == "params.geometry().world_position()")
        #expect(s["normal3d"] == "params.geometry().normal()")
        #expect(s["tangent"] == "params.geometry().tangent()")
        #expect(s["viewDirection"] == "params.geometry().view_direction()")
        #expect(s["screenPosition"] == "params.geometry().screen_position()")

        let g = EmitEnvironment.realityKitGeometry.sys
        #expect(g["uv"] == "geo.uv0()")
        #expect(g["time"] == "params.uniforms().time()")
        #expect(g["vertexID"] == "int(geo.vertex_id())")
        #expect(g["normal3d"] == "geo.normal()")
    }

    /// Group functions take `(float2 uv, float time, float2 size, float2 mouse, …)`, and the UV
    /// node's `aspect` variant reads `{sys.resolution}` — both keys must resolve to something
    /// even though no node can observe them as data (spec §23.4).
    @Test func resolutionAndMouseAreNeutralLiterals() {
        for env in [EmitEnvironment.realityKitSurface, EmitEnvironment.realityKitGeometry] {
            #expect(env.sys["resolution"] == "float2(1.0, 1.0)")
            #expect(env.sys["mouse"] == "float2(0.0, 0.0)")
        }
    }

    @Test func textureSamplesGoThroughTheCustomSlotAndFlipY() {
        let slot = TextureSlot(index: 0, asset: nil)
        let expr = EmitEnvironment.realityKitSurface.textureSample(slot, "uvExpr")
        #expect(expr.contains("tex0"))
        #expect(expr.contains("1.0 - "))
        // `texture2d<half>.sample` yields half4; the graph works in float4.
        #expect(expr.hasPrefix("float4("))
    }
}
