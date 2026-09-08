import Testing
@testable import MetalNodesCore

@Suite struct CustomAttributeTests {
    /// Writes a colour into customAttribute in the geometry stage and reads it back in the surface
    /// stage — the round trip the channel exists for.
    private func document() -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let t = NodeInstance(kind: .builtin("output.material"), position: .zero)
        var c = NodeInstance(kind: .builtin("input.color"), position: .zero)
        c.params["value"] = .float4(.init(1, 0, 0, 1))
        let read = NodeInstance(kind: .builtin("input.customAttribute"), position: .zero)
        for n in [t, c, read] { g.nodes[n.id] = n }
        g.inputs[SocketRef(t.id, "customAttribute")] = SocketRef(c.id, "out")
        g.inputs[SocketRef(t.id, "baseColor")] = SocketRef(read.id, "value")
        doc.root = g
        return doc
    }

    @Test func theTerminalGainsAGeometrySocket() {
        #expect(NodeRegistry.builtin["output.material"]?.input(named: "customAttribute")?.type == .concrete(.float4))
        #expect(BuiltinNodes.materialStages["customAttribute"] == .geometry)
    }

    @Test func theReaderNodeIsSurfaceOnly() {
        let d = NodeRegistry.builtin["input.customAttribute"]
        #expect(d?.outputs.first?.type == .concrete(.float4))
        #expect(d?.stages == [.surface])
    }

    @Test func theExportWritesInGeometryAndReadsInSurface() throws {
        let src = try #require(ShaderGenerator.generate(document(), target: .realityKit).exportSource)
        #expect(src.contains("geo.set_custom_attribute("))
        #expect(src.contains("params.geometry().custom_attribute()"))
    }

    @Test func thePreviewCarriesItAsAnInterpolant() throws {
        let src = try ShaderGenerator.generate(document(), target: .realityKit).source
        #expect(src.contains("float4 customAttribute;"))
        #expect(src.contains("o.customAttribute ="))
        #expect(src.contains("in.customAttribute"))
    }

    /// Reading it in the geometry stage is refused — it does not exist there.
    @Test func readingItInTheGeometryStageIsRefused() {
        var doc = document()
        let t = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let read = doc.root.nodes.values.first { $0.kind == .builtin("input.customAttribute") }!
        doc.root.inputs[SocketRef(t.id, "baseColor")] = nil
        doc.root.inputs[SocketRef(t.id, "customAttribute")] = SocketRef(read.id, "value")
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(!errs.isEmpty)
    }
}
