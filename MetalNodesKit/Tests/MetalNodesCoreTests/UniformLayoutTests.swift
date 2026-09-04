import Testing
@testable import MetalNodesCore

@Suite struct UniformLayoutTests {
    let n = NodeID()
    func path(_ p: String) -> ParamPath { ParamPath(node: n, param: p) }

    @Test func emptyLayoutHasOnlyReservedFields() {
        let l = UniformLayoutBuilder.build([])
        #expect(l.fields.map(\.name) == ["resolution", "mouse", "time"])
        #expect(l.reserved("resolution").offset == 0)
        #expect(l.reserved("mouse").offset == 8)
        #expect(l.reserved("time").offset == 16)
        #expect(l.totalSize == 32)
    }

    @Test func fieldsAreSortedByAlignmentDescending() {
        let l = UniformLayoutBuilder.build([(path("a"), .float), (path("b"), .float3), (path("c"), .float2), (path("d"), .int)])
        #expect(l.fields.map(\.mslType) == ["float3", "float2", "float2", "float2", "float", "float", "int"])
        #expect(l.field(for: path("b"))?.offset == 0)
        #expect(l.reserved("resolution").offset == 16)
    }

    @Test func float3OccupiesSixteenBytes() {
        let l = UniformLayoutBuilder.build([(path("a"), .float3), (path("b"), .float3)])
        #expect(l.field(for: path("a"))?.offset == 0)
        #expect(l.field(for: path("b"))?.offset == 16)
        #expect(l.field(for: path("a"))?.size == 16)
    }

    @Test func totalSizeIsMultipleOfSixteen() {
        for k in 0..<6 {
            let reqs = (0..<k).map { (path("p\($0)"), SocketType.float) }
            #expect(UniformLayoutBuilder.build(reqs).totalSize % 16 == 0)
        }
    }

    @Test func userFieldsAreNamedInFinalOrder() {
        let l = UniformLayoutBuilder.build([(path("a"), .float), (path("b"), .float4)])
        #expect(l.field(for: path("b"))?.name == "p0")
        #expect(l.field(for: path("a"))?.name == "p1")
    }

    @Test func boolStoresAsInt() {
        let l = UniformLayoutBuilder.build([(path("flag"), .bool)])
        #expect(l.field(for: path("flag"))?.mslType == "int")
        #expect(l.field(for: path("flag"))?.type == .bool)
    }

    @Test func mslStructMatchesFieldOrder() {
        let l = UniformLayoutBuilder.build([(path("a"), .float)])
        let expected = """
        struct Uniforms {
            float2 resolution;
            float2 mouse;
            float time;
            float p0;
        };
        """
        #expect(l.mslStruct == expected)
    }

    @Test func sortIsStableWithinAnAlignmentClass() {
        let l = UniformLayoutBuilder.build([(path("x"), .float), (path("y"), .int), (path("z"), .float)])
        #expect(l.fields.filter { $0.path != nil }.map(\.path!.param) == ["x", "y", "z"])
    }
}
