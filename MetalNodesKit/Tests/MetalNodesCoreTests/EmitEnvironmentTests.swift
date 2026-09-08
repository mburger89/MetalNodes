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
        #expect(env.sys["uv"]?.spelling == "in.uv")
        #expect(env.sys["time"]?.spelling == "u.time")
        #expect(env.sys["resolution"]?.spelling == "u.resolution")
        #expect(env.sys["mouse"]?.spelling == "u.mouse")
    }

    @Test func stitchableEnvironmentReadsArgumentsAndCastsScalars() {
        let env = EmitEnvironment.stitchableFunction
        #expect(env.uniform(field("p0", .float)) == "p0")
        #expect(env.uniform(field("p3", .int)) == "int(p3)")
        #expect(env.uniform(field("p4", .bool)) == "bool(p4)")
        // SwiftUI passes `.color(_:)` as a premultiplied half4, so a colour argument is widened on read.
        #expect(env.uniform(field("p5", .color)) == "float4(p5)")
        #expect(env.uniform(field("p6", .float4)) == "p6")
        #expect(env.sys["uv"]?.spelling == "uv")
        #expect(env.sys["resolution"]?.spelling == "size")
        #expect(env.sys["mouse"]?.spelling == "mouse")
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
        #expect(s["uv"]?.spelling == "params.geometry().uv0()")
        #expect(s["time"]?.spelling == "params.uniforms().time()")
        #expect(s["worldPosition"]?.spelling == "params.geometry().world_position()")
        #expect(s["normal3d"]?.spelling == "params.geometry().normal()")
        #expect(s["tangent"]?.spelling == "params.geometry().tangent()")
        #expect(s["viewDirection"]?.spelling == "params.geometry().view_direction()")
        #expect(s["screenPosition"]?.spelling == "params.geometry().screen_position()")

        let g = EmitEnvironment.realityKitGeometry.sys
        #expect(g["uv"]?.spelling == "geo.uv0()")
        #expect(g["time"]?.spelling == "params.uniforms().time()")
        #expect(g["vertexID"]?.spelling == "int(geo.vertex_id())")
        #expect(g["normal3d"]?.spelling == "geo.normal()")
    }

    /// Group functions take `(float2 uv, float time, float2 size, float2 mouse, …)` and a RealityKit
    /// material spells that argument list from these keys, so both must resolve to something. That
    /// call site is the *only* reason they exist: `readable == false` is what stops them being
    /// values a node can observe (spec §23.4, amended by §24.10).
    ///
    /// M7 also justified them by the UV node's `aspect` variant reading `{sys.resolution}` — in the
    /// same breath as "no node can observe them as data", which cannot both be true. M8 resolved it
    /// against the permissive reading, so that variant is now refused under this target too.
    @Test func resolutionAndMouseAreNeutralLiterals() {
        for env in [EmitEnvironment.realityKitSurface, EmitEnvironment.realityKitGeometry] {
            #expect(env.sys["resolution"]?.spelling == "float2(1.0, 1.0)")
            #expect(env.sys["resolution"]?.readable == false)
            #expect(env.sys["mouse"]?.spelling == "float2(0.0, 0.0)")
            #expect(env.sys["mouse"]?.readable == false)
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

    @Test func replacingTheUniformSpellerKeepsEveryOtherField() {
        let env = EmitEnvironment.realityKitSurface
        let baked = env.withUniformSpeller { _ in "1.0" }
        #expect(baked.knownAccessors == env.knownAccessors)
        #expect(!baked.knownAccessors.isEmpty)
        #expect(baked.sys.keys.sorted() == env.sys.keys.sorted())
        #expect(baked.usesLayer == env.usesLayer)
    }
}
