import Foundation
import Testing
@testable import MetalNodesCore

@Suite struct LiveParametersTests {
    private func document(live: Int) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "liveMat"
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        var paths: [ParamPath] = []
        for i in 0..<max(live, 1) {
            var f = NodeInstance(kind: .builtin("input.float"), position: .zero)
            f.params["value"] = .float(Float(i) * 0.25)
            g.nodes[f.id] = f
            let socket = ["roughness", "metallic", "opacity", "specular", "occlusion"][i]
            g.inputs[SocketRef(terminal.id, socket)] = SocketRef(f.id, "out")
            paths.append(ParamPath(node: f.id, param: "value"))
        }
        doc.root = g
        doc.settings.liveParameters = Array(paths.prefix(live))
        return doc
    }

    @Test func settingsRoundTrip() throws {
        let doc = document(live: 2)
        let back = try JSONDecoder().decode(ShaderDocument.self, from: try JSONEncoder().encode(doc))
        #expect(back.settings.liveParameters == doc.settings.liveParameters)
    }

    @Test func settingsWithoutTheKeyDecodeAsEmpty() throws {
        let json = Data(#"{"fastMath":true,"exportName":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json).liveParameters.isEmpty)
    }

    @Test func aLiveParameterReadsCustomParameterInTheExport() throws {
        let src = try #require(ShaderGenerator.generate(document(live: 2), target: .realityKit).exportSource)
        #expect(src.contains("params.uniforms().custom_parameter().x"))
        #expect(src.contains("params.uniforms().custom_parameter().y"))
    }

    @Test func aBakedParameterStillBakes() throws {
        let src = try #require(ShaderGenerator.generate(document(live: 0), target: .realityKit).exportSource)
        #expect(!src.contains("custom_parameter()"))
    }

    /// §23.6's baking is a property of the export, not of the graph — the preview keeps reading
    /// the uniform buffer whether a parameter is live or not.
    ///
    /// Both generations hold the *same* graph fixed (`document(live: 2)`'s two float nodes) and
    /// vary only `settings.liveParameters` — comparing `document(live: 0)` against
    /// `document(live: 2)` directly, as an earlier draft of this test did, compares two graphs of
    /// different shape (one wired float node vs. two) and would fail on that difference alone,
    /// independent of whether marking a parameter live changes the preview.
    @Test func thePreviewIsUnchangedByMarkingAParameterLive() throws {
        var unmarked = document(live: 2)
        unmarked.settings.liveParameters = []
        let a = try ShaderGenerator.generate(unmarked, target: .realityKit).source
        let b = try ShaderGenerator.generate(document(live: 2), target: .realityKit).source
        #expect(a == b)
    }

    @Test func aFifthLiveParameterIsRefused() {
        var doc = document(live: 4)
        let extra = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        doc.settings.liveParameters.append(ParamPath(node: extra.id, param: "value"))
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(errs.contains { $0.message.lowercased().contains("four") })
    }

    @Test func aNonFloatLiveParameterIsRefused() {
        var doc = document(live: 0)
        let color = NodeInstance(kind: .builtin("input.color"), position: .zero)
        doc.root.nodes[color.id] = color
        doc.settings.liveParameters = [ParamPath(node: color.id, param: "value")]
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(errs.contains { $0.message.lowercased().contains("float") })
    }

    /// `vector.length`'s `v` is declared `.generic("T")`, defaulting to `.float2` — its declared
    /// type has no concrete answer on its own, unlike `input.color`'s `value` above. Before
    /// `MaterialValidation.fieldType` fell back to `ParamValues.value(...).socketType`, this path
    /// resolved to `nil` and slipped through unjudged: `GraphValidator.validate` reported zero
    /// diagnostics, and the export emitted `length(params.uniforms().custom_parameter().x)`, which
    /// `xcrun -sdk macosx metal -c` refuses — "call to 'length' is ambiguous" — with nothing in the
    /// editor having said why.
    @Test func aGenericVectorLiveParameterIsRefused() {
        var doc = document(live: 0)
        let length = NodeInstance(kind: .builtin("vector.length"), position: .zero)
        doc.root.nodes[length.id] = length
        doc.settings.liveParameters = [ParamPath(node: length.id, param: "v")]
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(errs.contains { $0.message.lowercased().contains("float") })
    }

    @Test func duplicateLiveParametersAreRefused() {
        var doc = document(live: 1)
        doc.settings.liveParameters = [doc.settings.liveParameters[0], doc.settings.liveParameters[0]]
        let errs = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
            .filter { $0.severity == .error }
        #expect(errs.contains { $0.message.lowercased().contains("more than once") })
    }

    /// Pins the actual seeded values (and their order), not just the substring "custom.value" —
    /// that substring alone is satisfied by this task's own doc comment above the setter
    /// ("`material.custom.value` carries the live parameters below"), so a version of this test
    /// that only checked `contains("custom.value")` passed even when the setter emission itself was
    /// deleted entirely. Verified against that mutation while fixing this: replacing the setter
    /// line's body with a no-op left all tests in this file passing except this one.
    @Test func theSwiftSnippetExposesTheLiveValues() throws {
        let files = try ShaderExport.files(for: document(live: 2))
        let swift = try #require(files.first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("material.custom.value = SIMD4<Float>(0.0, 0.25, 0.0, 0.0)"))
    }

    /// A live parameter's input rewired away after being marked live has no matching
    /// `UniformLayout` field — `bakedUniforms` never substitutes for it, so the `.metal` reads no
    /// `custom_parameter()` at all. The header and the Swift snippet must not document or seed a
    /// component the export doesn't touch either, or the reader writes to `.x` from Swift and
    /// nothing animates, with nothing saying why.
    @Test func aLiveParameterWhoseNodeIsNoLongerWiredIsNotDocumentedOrSeeded() throws {
        var doc = document(live: 1)
        let live = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let other = NodeInstance(kind: .builtin("input.float"), position: .zero)
        doc.root.nodes[other.id] = other
        doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(other.id, "out")
        // `doc.settings.liveParameters` still names `live`'s "value" — nothing rewires the
        // setting itself, only the graph moves out from under it.
        #expect(doc.settings.liveParameters == [ParamPath(node: live.id, param: "value")])

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        #expect(!(shader.exportSource ?? "").contains("custom_parameter()"))
        let files = try ShaderExport.files(for: doc)
        let metal = try #require(files.first { $0.name.hasSuffix(".metal") })
        let swift = try #require(files.first { $0.name.hasSuffix(".swift") })
        #expect(!metal.contents.contains("Live parameters"))
        #expect(!swift.contents.contains("custom.value"))
    }
}
