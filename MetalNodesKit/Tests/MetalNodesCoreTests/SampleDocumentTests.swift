import Testing
import Foundation
@testable import MetalNodesCore

/// `customCodeSample()` — the M8 sample document (spec §24). `LibraryM3Tests`'
/// `everyLibraryDocumentValidatesAndGeneratesUnderItsOwnTarget` already sweeps it for "validates
/// and generates"; this suite is the part a sweep cannot make, namely that the generated source
/// really carries *both* new node kinds rather than a document that happens to compile with one of
/// them silently dropped.
@Suite struct SampleDocumentTests {
    let reg = NodeRegistry.builtin

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: doc.settings.target, registry: reg).source
    }

    @Test func theCustomCodeSampleValidatesCleanUnderItsOwnTarget() {
        let doc = ShaderDocument.customCodeSample()
        #expect(doc.settings.target == .realityKit)
        let diags = GraphValidator.validate(document: doc, registry: reg, target: doc.settings.target)
        #expect(diags.isEmpty, "\(diags)")
    }

    /// The two features, asserted through the *emitted text* rather than through the graph, because
    /// a wire into a terminal socket that codegen never reads would still validate. `in_c` is the
    /// spelling that proves a Custom MSL body reached the emitted function intact, and the two
    /// clamp bounds are unique enough to the sample's formula that no other emitted line carries
    /// them.
    @Test func theCustomCodeSampleEmitsBothNewNodeKinds() throws {
        let s = try source(.customCodeSample())
        #expect(!s.contains("/* ?"))                                  // no unsubstituted placeholder
        #expect(s.contains("in_c * float3(1.0, 0.85, 0.7)"))          // the Custom MSL body
        #expect(s.contains("clamp("), "\(s)")                         // the Expression's formula …
        #expect(s.contains("0.05, 0.95)"))                            // … inlined, not called
        // A definition is emitted as exactly one function no matter how many instances it has.
        #expect(s.components(separatedBy: "mn_g_Tint").count - 1 >= 2) // declaration + call site
    }

    /// The sample declares `.realityKit`, and a document cannot carry both terminals — validation
    /// requires the target's own terminal and refuses the other (`ShaderGenerator.generate`'s own
    /// comment: "a RealityKit document has no Fragment Output and vice versa"). So "generates for
    /// `.fragment` too" is asserted of the sample's *content*: the same definition body and the
    /// same formula, re-terminated on a Fragment Output.
    @Test func theSameContentGeneratesUnderFragmentToo() throws {
        let s = try source(fragmentVariant(of: .customCodeSample()))
        #expect(!s.contains("/* ?"))
        #expect(s.contains("in_c * float3(1.0, 0.85, 0.7)"))
        #expect(s.contains("0.05, 0.95)"))
    }

    /// The check M7 paid for the hard way (handoff §14): the two defects that cost most that
    /// milestone passed every text assertion and failed at launch. A sample document is the one
    /// artefact a human is told to open, so its export gets a real `xcrun metal` compile — on both
    /// terminations — rather than a substring check. Skips silently when the toolchain is absent,
    /// the same mechanism `MaterialExportCompilesTests` uses.
    @Test func theCustomCodeSampleExportCompilesWithXcrunMetal() throws {
        guard MetalCompiler.isAvailable else { return }

        try expectMetalCompiles(.customCodeSample())
        var fragment = fragmentVariant(of: .customCodeSample())
        fragment.settings.exportName = "customCodeSampleFragment"
        try expectMetalCompiles(fragment)
    }

    private func expectMetalCompiles(_ doc: ShaderDocument) throws {
        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        try MetalCompiler.expectCompiles(file.contents, doc.settings.exportName)
    }

    /// Re-terminates the material sample on a Fragment Output, keeping every other node, the Custom
    /// MSL definition and the Expression's formula exactly as the sample spells them. The Mix is
    /// there so the Expression stays *reachable*: a Fragment Output has one `color` input, and an
    /// Expression wired to nothing would be dropped by dead-code elimination, leaving this test
    /// passing while covering only half of what it claims.
    private func fragmentVariant(of doc: ShaderDocument) -> ShaderDocument {
        var d = doc
        d.settings.target = .fragment
        let material = d.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let baseColour = d.root.inputs[SocketRef(material.id, "baseColor")]!
        let roughness = d.root.inputs[SocketRef(material.id, "roughness")]!
        let colour = d.root.nodes.values.first { $0.kind == .builtin("input.color") }!
        d.root.remove(node: material.id)

        let mix = NodeInstance(kind: .builtin("math.mix"), position: CGPoint(x: 560, y: 100))
        let out = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 780, y: 100))
        d.root.nodes[mix.id] = mix
        d.root.nodes[out.id] = out
        d.root.connect(baseColour, to: SocketRef(mix.id, "a"))                  // the Custom MSL out
        d.root.connect(SocketRef(colour.id, "out"), to: SocketRef(mix.id, "b"))
        d.root.connect(roughness, to: SocketRef(mix.id, "t"))                   // the Expression out
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        return d
    }
}
