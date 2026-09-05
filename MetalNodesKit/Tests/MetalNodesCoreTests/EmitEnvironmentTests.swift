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
