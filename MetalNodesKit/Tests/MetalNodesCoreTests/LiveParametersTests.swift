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

    @Test func theSwiftSnippetExposesTheLiveValues() throws {
        let files = try ShaderExport.files(for: document(live: 2))
        let swift = try #require(files.first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("custom.value"))
    }
}
