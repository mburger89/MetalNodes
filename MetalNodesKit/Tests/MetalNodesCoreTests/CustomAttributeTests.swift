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

    /// Asserts the *argument*, not just the call shape: `document()` wires a known red
    /// (`(1, 0, 0, 1)`) into `customAttribute`, so the setter must carry that node's own SSA
    /// variable, and the variable itself must be the literal that node emits — not just some call
    /// named `set_custom_attribute` with anything inside the parens. A body that always exported
    /// `geo.set_custom_attribute(float4(0.0));` (every wired custom attribute rendering black)
    /// would still satisfy a substring check on the call name alone; it fails these two.
    @Test func theExportWritesInGeometryAndReadsInSurface() throws {
        let src = try #require(ShaderGenerator.generate(document(), target: .realityKit).exportSource)
        // Whichever SSA name the colour node lands on, the setter must name *that* variable.
        let name = try #require(src.firstMatch(of: /(v\d+) = float4\(1\.0, 0\.0, 0\.0, 1\.0\);/)?.1)
        #expect(src.contains("geo.set_custom_attribute(\(name))"))
        #expect(src.contains("params.geometry().custom_attribute()"))
    }

    /// Same discrimination as above, for the preview: `o.customAttribute = v0;` must name the real
    /// variable the geometry stage's own statements produced, not a fixed `float4(0.0)` that would
    /// render every wired document black regardless of what was wired.
    @Test func thePreviewCarriesItAsAnInterpolant() throws {
        // The preview path reads uniforms live (`u.pN`), not baked literals, so the SSA name is
        // pulled from `exportSource` — same emission order, so the same variable number — rather
        // than matched against a literal that only the export path ever emits.
        let generated = try ShaderGenerator.generate(document(), target: .realityKit)
        let src = generated.source
        #expect(src.contains("float4 customAttribute;"))
        let name = try #require(generated.exportSource?.firstMatch(of: /(v\d+) = float4\(1\.0, 0\.0, 0\.0, 1\.0\);/)?.1)
        #expect(src.contains("o.customAttribute = \(name);"))
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
