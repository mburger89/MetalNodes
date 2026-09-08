import Testing
import Foundation
import CoreGraphics
import Metal
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Records generations and never publishes, so tests can count compiles deterministically.
actor RecordingCompiler: ShaderCompiling {
    private(set) var generations: [UInt64] = []
    private(set) var fastMathFlags: [Bool] = []
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        generations.append(generation)
        fastMathFlags.append(fastMath)
        return .superseded(generation: generation)
    }
}

/// Always fails with one warning and one error line so severity mapping can be observed.
actor WarningCompiler: ShaderCompiling {
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        .failure(message: "synthetic", lines: [
            CompileLine(line: 1, severity: .warning, message: "header warning"),      // line 1 has no node owner
            CompileLine(line: 999, severity: .error, message: "nowhere"),
        ], generation: generation)
    }
}

/// Fails every time and counts how often it was asked — the outcome that must be *reused* for unchanged source.
actor CountingFailingCompiler: ShaderCompiling {
    private(set) var calls = 0
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        calls += 1
        return .failure(message: "synthetic", lines: [CompileLine(line: 999, message: "nowhere")], generation: generation)
    }
}

/// Compiles for real until a test switches it to failing. The only way to observe what happens after
/// a compile has actually landed: a stub cannot mint a `CompiledPipeline`, which owns a real
/// `MTLRenderPipelineState`.
actor SwitchableCompiler: ShaderCompiling {
    private let real: ShaderCompiler
    private var failing = false
    init(device: MTLDevice) throws { self.real = try ShaderCompiler(device: device) }
    func setFailing(_ on: Bool) { failing = on }
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        guard !failing else { return .failure(message: "synthetic", lines: [], generation: generation) }
        return await real.compile(shader, generation: generation, fastMath: fastMath)
    }
}

@MainActor
@Suite struct EditorModelTests {
    private func model(_ compiler: any ShaderCompiling) -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: compiler)
        m.debounceInterval = .milliseconds(5)
        return m
    }

    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func classification() {
        let id = NodeID()
        #expect(DocumentChange.moveNodes([id: .zero]).changeClass == .cosmetic)
        #expect(DocumentChange.setParam(id, "value", .float(1)).changeClass == .parameter)
        #expect(DocumentChange.setParam(id, "op", .enumCase("sine")).changeClass == .topology)
        #expect(DocumentChange.connect(from: SocketRef(id, "a"), to: SocketRef(id, "b")).changeClass == .topology)
        #expect(DocumentChange.disconnect(SocketRef(id, "a")).changeClass == .topology)
        #expect(DocumentChange.removeNodes([id]).changeClass == .topology)
        #expect(DocumentChange.setTitle(id, "x").changeClass == .cosmetic)
        #expect(DocumentChange.insert(nodes: [], edges: []).changeClass == .topology)
        // Settings are cosmetic on their own; `apply` upgrades a `fastMath` flip to a recompile,
        // which needs the previous settings (spec §18.2) — see the two tests below.
        #expect(DocumentChange.setSettings(DocumentSettings()).changeClass == .cosmetic)
    }

    @Test func fastMathChangeRecompiles() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        var s = m.document.settings; s.fastMath = false
        m.apply(.setSettings(s))
        await m.awaitIdle()
        #expect(m.document.settings.fastMath == false)
        #expect(await c.generations.count == 2)
        #expect(await c.fastMathFlags == [true, false])
    }

    /// The lighting model selects which setters the material emits and whether the preview
    /// program carries the GGX helpers at all, so flipping it changes the source (spec §23.8).
    @Test func lightingModelChangeRecompiles() async {
        let c = RecordingCompiler()
        // A RealityKit document, so the material actually generates — a fragment graph has no
        // Material Output and would fail validation before ever reaching the compiler.
        let m = EditorModel(document: .realityKitMaterial(), compiler: c)
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        let before = await c.generations.count
        var s = m.document.settings
        s.lightingModel = .unlit
        m.apply(.setSettings(s))
        await m.awaitIdle()
        #expect(m.document.settings.lightingModel == .unlit)
        #expect(await c.generations.count == before + 1)
    }

    /// The whole `.setSettings` recompile matrix in one place. `EditorModel.perform` decides
    /// this by hand, field by field, and nothing enforces that the list stays in step with what
    /// actually reaches codegen — a missing field leaves the old program on screen with no error,
    /// which is how the lighting model shipped broken. Add a row here whenever a setting starts
    /// or stops affecting the generated source.
    @Test func everySettingThatReachesCodegenRecompiles() async {
        func recompiles(_ document: ShaderDocument, _ mutate: (inout DocumentSettings) -> Void) async -> Bool {
            let c = RecordingCompiler()
            let m = EditorModel(document: document, compiler: c)
            m.debounceInterval = .milliseconds(5)
            m.start(); await m.awaitIdle()
            let before = await c.generations.count
            var s = m.document.settings
            mutate(&s)
            m.apply(.setSettings(s))
            await m.awaitIdle()
            return await c.generations.count > before
        }

        var stitchable = ShaderDocument.sample()
        stitchable.settings.target = .stitchable(.colorEffect)

        // Reaches codegen — must rebuild.
        #expect(await recompiles(.sample()) { $0.fastMath.toggle() })
        #expect(await recompiles(.sample()) { $0.target = .stitchable(.colorEffect) })
        #expect(await recompiles(stitchable) { $0.exportName = "renamed" })
        #expect(await recompiles(.realityKitMaterial()) { $0.lightingModel = .unlit })
        // liveParameters only changes what the export spells for a baked field (spec §24.6) — the
        // preview itself never reads it — but the export is produced by the same compile pass as
        // the preview, so marking a parameter live still needs a rebuild.
        let material = ShaderDocument.realityKitMaterial()
        let liveFloat = material.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        #expect(await recompiles(material) { $0.liveParameters = [ParamPath(node: liveFloat.id, param: "value")] })

        // Does not reach codegen — must not rebuild.
        #expect(await recompiles(.sample()) { $0.previewSize = CGSize(width: 256, height: 256) } == false)
        #expect(await recompiles(.sample()) { $0.timeMode = .fixedRate } == false)
        // The export name names no function in a fragment program.
        #expect(await recompiles(.sample()) { $0.exportName = "renamed" } == false)
        // Not under the RealityKit target: nothing reads `custom_parameter()` there either.
        #expect(await recompiles(.sample()) { $0.liveParameters = [ParamPath(node: NodeID(), param: "value")] } == false)
    }

    /// A live parameter naming a node that is then deleted would otherwise leave the export
    /// spelling `params.uniforms().custom_parameter().x` for a slot nothing writes (spec §24.6).
    @Test func removingALiveParametersNodePrunesTheSetting() async {
        let m = EditorModel(document: .realityKitMaterial(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        let f = node(m, "input.float")
        var s = m.document.settings
        s.liveParameters = [ParamPath(node: f.id, param: "value")]
        m.apply(.setSettings(s))
        #expect(m.document.settings.liveParameters == [ParamPath(node: f.id, param: "value")])
        m.apply(.removeNodes([f.id]))
        #expect(m.document.settings.liveParameters.isEmpty)
    }

    @Test func previewSizeOnlyChangeDoesNotRecompile() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        var s = m.document.settings
        s.previewSize = CGSize(width: 256, height: 256)
        s.timeMode = .fixedRate
        m.apply(.setSettings(s))
        await m.awaitIdle()
        #expect(m.document.settings.previewSize == CGSize(width: 256, height: 256))
        #expect(await c.generations.count == 1)
    }

    @Test func removeNodesPrunesSelectionAndDropsWires() async {
        let m = model(RecordingCompiler())
        let uv = node(m, "input.uv"), sep = node(m, "vector.separate")
        m.viewState.selection = [uv.id, sep.id]
        m.apply(.removeNodes([uv.id]))
        #expect(m.viewState.selection == [sep.id])
        #expect(m.document.root.inputs.values.contains { $0.node == uv.id } == false)
    }

    @Test func insertAddsNodesThenWiresInOneChange() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        let a = NodeInstance(kind: .builtin("input.time")), b = NodeInstance(kind: .builtin("math.math"))
        m.apply(.insert(nodes: [a, b], edges: [Edge(to: SocketRef(b.id, "a"), from: SocketRef(a.id, "time"))]))
        await m.awaitIdle()
        #expect(m.document.root.source(feeding: SocketRef(b.id, "a")) == SocketRef(a.id, "time"))
        #expect(await c.generations.count == 2)
    }

    @Test func setTitleIsCosmeticAndEmptyClears() async {
        let c = RecordingCompiler()
        let m = model(c); m.start(); await m.awaitIdle()
        let uv = node(m, "input.uv")
        m.apply(.setTitle(uv.id, "Coords"))
        #expect(m.document.root.nodes[uv.id]?.customTitle == "Coords")
        m.apply(.setTitle(uv.id, ""))
        #expect(m.document.root.nodes[uv.id]?.customTitle == nil)
        await m.awaitIdle()
        #expect(await c.generations.count == 1)
    }

    @Test func startCompilesOnce() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start()
        await m.awaitIdle()
        #expect(await c.generations == [1])
        #expect(!m.generatedSource.isEmpty)
        #expect(m.resolvedTypes.count == 11)
    }

    @Test func cosmeticChangeDoesNotCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let uv = node(m, "input.uv")
        m.apply(.moveNodes([uv.id: CGPoint(x: 5, y: 5)]))
        await m.awaitIdle()
        #expect(await c.generations.count == 1)
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 5, y: 5))
    }

    @Test func rapidTopologyChangesCoalesceIntoOneCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let sine = node(m, "math.math")
        for op in ["cosine", "sine", "fract"] { m.apply(.setParam(sine.id, "op", .enumCase(op))) }
        await m.awaitIdle()
        #expect(await c.generations == [1, 2])
    }

    @Test func awaitIdleWaitsForEditsThatLandMidAwait() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        let sine = node(m, "math.math")
        m.apply(.setParam(sine.id, "op", .enumCase("cosine")))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1))
            m.apply(.setParam(sine.id, "op", .enumCase("sine")))
        }
        await m.awaitIdle()
        #expect(await c.generations.count == 2)
    }

    @Test func invalidGraphReportsDiagnosticsAndDoesNotCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        m.apply(.removeNodes([node(m, "output.fragment").id]))
        await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.message.contains("Fragment Output") })
        #expect(await c.generations == [1])
    }

    @Test func parameterChangeWritesUniformsWithoutRecompiling() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — these tests need a GPU")
        let real = try ShaderCompiler(device: device)
        let m = model(real)
        m.start(); await m.awaitIdle()
        let pipeline = try #require(m.preview.pipeline)
        let speed = node(m, "input.float")
        let before = try #require(m.preview.uniforms).bytes
        m.apply(.setParam(speed.id, "value", .float(0.9)))
        await m.awaitIdle()
        #expect(m.preview.uniforms?.bytes != before)
        #expect(m.preview.pipeline?.generation == pipeline.generation)
        #expect(m.document.root.nodes[speed.id]?.params["value"] == .float(0.9))
    }

    @Test func compileFailureKeepsLastGoodPipelineAndMapsLines() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — these tests need a GPU")
        let m = model(try ShaderCompiler(device: device))
        m.start(); await m.awaitIdle()
        let good = try #require(m.preview.pipeline)
        // A bad template can only come from a bad registry; simulate via a broken definition.
        let broken = NodeDef(id: "t.broken", title: "Broken", category: .utility,
                             outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                             body: .template("{out.out} = this_is_not_msl;"))
        let reg = try NodeRegistry(BuiltinNodes.all + [broken])
        let m2 = EditorModel(document: .sample(), compiler: try ShaderCompiler(device: device), registry: reg)
        m2.debounceInterval = .milliseconds(5)
        m2.start(); await m2.awaitIdle()
        let b = NodeInstance(kind: .builtin("t.broken"))
        let out = node(m2, "output.fragment")
        m2.apply(.addNode(b))
        m2.apply(.connect(from: SocketRef(b.id, "out"), to: SocketRef(out.id, "color")))
        await m2.awaitIdle()
        #expect(m2.preview.lastError != nil)
        #expect(m2.preview.pipeline != nil)
        #expect(m2.diagnostics.contains { $0.node == b.id })
        _ = good
    }

    @Test func compilerSeverityMapsToDiagnosticsAndUnmappedLinesSurvive() async {
        let m = EditorModel(document: .sample(), compiler: WarningCompiler())
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.severity == .warning && $0.message == "header warning" && $0.node == nil })
        #expect(m.diagnostics.contains { $0.severity == .error && $0.message == "nowhere" })
        #expect(m.preview.pipeline == nil)
        #expect(m.preview.lastError == "synthetic")
    }

    @Test func fastMathSettingReachesTheCompiler() async {
        let c = RecordingCompiler()
        var doc = ShaderDocument.sample()
        doc.settings.fastMath = false
        let m = EditorModel(document: doc, compiler: c)
        m.start(); await m.awaitIdle()
        #expect(await c.fastMathFlags == [false])
    }

    @Test func unchangedSourceSkipsTheCompiler() async {
        // `RecordingCompiler` answers `.superseded`, which never settles a program; a failing
        // compiler does (its diagnostics stand until the source changes), so count with that.
        let c = CountingFailingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        #expect(await c.calls == 1)
        #expect(!m.diagnostics.isEmpty)
        let uv = node(m, "input.uv")
        m.apply(.moveNodes([uv.id: CGPoint(x: 5, y: 5)]))        // cosmetic: no compile at all
        m.undo(); await m.awaitIdle()                              // restore: topology, but same source
        #expect(await c.calls == 1)
        #expect(!m.diagnostics.isEmpty)                            // the standing failure is kept
        var s = m.document.settings; s.fastMath = false
        m.apply(.setSettings(s)); await m.awaitIdle()              // same source, different cache key
        #expect(await c.calls == 2)
    }

    @Test func changingTheTargetRecompiles() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        var s = m.document.settings; s.target = .stitchable(.colorEffect)
        m.apply(.setSettings(s)); await m.awaitIdle()
        #expect(await c.generations.count == 2)
        #expect(m.generatedSource.contains("half4 metalNodesShader("))
    }

    /// The export name is the stitchable function's name, so it is baked into the generated source.
    @Test func renamingUnderAStitchableTargetRecompiles() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        var s = m.document.settings; s.target = .stitchable(.colorEffect)
        m.apply(.setSettings(s)); await m.awaitIdle()
        #expect(await c.generations.count == 2)

        s = m.document.settings; s.exportName = "aurora"
        m.apply(.setSettings(s)); await m.awaitIdle()
        #expect(await c.generations.count == 3)
        #expect(m.generatedSource.contains("half4 aurora("))
    }

    @Test func renamingUnderTheFragmentTargetDoesNotRecompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        #expect(await c.generations.count == 1)
        var s = m.document.settings; s.exportName = "aurora"
        m.apply(.setSettings(s)); await m.awaitIdle()
        #expect(await c.generations.count == 1)
    }

    @Test func copySwiftSnippetWritesPlainTextOnlyForStitchableTargets() throws {
        let pb = MemoryPasteboard()
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler(), pasteboard: pb)
        #expect(!m.copySwiftSnippet())
        var s = m.document.settings; s.target = .stitchable(.colorEffect); s.exportName = "demo"
        m.apply(.setSettings(s))
        #expect(m.copySwiftSnippet())
        let text = String(decoding: try #require(pb.read(type: "public.utf8-plain-text")), as: UTF8.self)
        #expect(text.contains("ShaderLibrary.demo("))
    }

    @Test func exportFilesFollowTheDocumentTarget() throws {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        #expect(try m.exportFiles().map(\.name) == ["metalNodesShader.metal"])
        var s = m.document.settings; s.target = .stitchable(.layerEffect)
        m.apply(.setSettings(s))
        #expect(try m.exportFiles().map(\.name) == ["metalNodesShader.metal", "metalNodesShader.swift"])
        let before = m.exportRequest
        m.requestExport()
        #expect(m.exportRequest == before + 1)
    }

    /// The bindings belong to the pipeline that is actually drawing, not to the program the editor
    /// last generated: a generation whose Metal compile fails leaves the last-good pipeline live, and
    /// rebinding to the new program's (here empty) slots would leave that pipeline's `tex0` unbound.
    @Test func textureBindingsFollowTheLivePipeline() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — this test needs a GPU")
        let c = try SwitchableCompiler(device: device)
        let asset = AssetID(raw: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!)
        var d = ShaderDocument()
        d.settings.assets[asset] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        let sample = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(asset)])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[sample.id] = sample; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(sample.id, "color"), to: SocketRef(out.id, "color"))

        let m = EditorModel(document: d, compiler: c, textureStore: TextureStore(device: device))
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        #expect(m.textureSlots == [TextureSlot(index: 0, asset: asset)])
        #expect(m.preview.program?.textures.count == 1)

        // A program that generates but does not compile: the pipeline drawing the preview is still
        // the one that samples the asset, so its slot must stay bound.
        await c.setFailing(true)
        m.apply(.removeNodes([sample.id]))
        await m.awaitIdle()
        #expect(m.preview.lastError == "synthetic")
        #expect(m.textureSlots == [TextureSlot(index: 0, asset: asset)])
        #expect(m.preview.program?.textures.count == 1)

        // And once a compile lands, they follow it — the new pipeline declares no slot.
        await c.setFailing(false)
        var s = m.document.settings; s.fastMath = false
        m.apply(.setSettings(s))
        await m.awaitIdle()
        #expect(m.preview.lastError == nil)
        #expect(m.textureSlots.isEmpty)
        #expect(m.preview.program?.textures.isEmpty == true)
    }

    /// Giving an unassigned Texture Sample an image changes no source text — only which asset the
    /// `tex0` slot names — so the "same program" shortcut must look at the slots too, or the
    /// pipeline that keeps drawing is the one whose slot is still empty (manual check M5-4, M6).
    @Test func choosingAnImageForAnEmptySampleRebindsItsSlot() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — this test needs a GPU")
        let c = try SwitchableCompiler(device: device)
        var d = ShaderDocument()
        let sample = NodeInstance(kind: .builtin("texture.sample"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[sample.id] = sample; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(sample.id, "color"), to: SocketRef(out.id, "color"))
        let store = TextureStore(device: device)
        let m = EditorModel(document: d, compiler: c, textureStore: store)
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        #expect(m.textureSlots == [TextureSlot(index: 0, asset: nil)])
        let sourceBefore = m.generatedSource

        // What `chooseImage(for:param:from:using:)` does once the chooser returns.
        m.beginTransaction("Choose Image")
        let id = try #require(m.importImage(data: EditorAssetsTests.png2x2, name: "a.png"))
        m.apply(.setParam(sample.id, "asset", .asset(id)))
        m.endTransaction()
        await m.awaitIdle()

        #expect(m.generatedSource == sourceBefore)
        #expect(m.textureSlots == [TextureSlot(index: 0, asset: id)])
        let bound = try #require(m.preview.program?.textures[0])
        #expect(bound !== store.placeholder)
    }

    /// A failed compile must not touch the program at all: the generation and the bindings the
    /// renderer reads are the ones from the last landed compile, together.
    @Test func aFailedCompileLeavesThePublishedProgramIntact() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — this test needs a GPU")
        let c = try SwitchableCompiler(device: device)
        let m = EditorModel(document: .starter(), compiler: c, textureStore: TextureStore(device: device))
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        let landed = try #require(m.preview.program)
        await c.setFailing(true)
        var s = m.document.settings; s.fastMath = false
        m.apply(.setSettings(s)); await m.awaitIdle()
        #expect(m.preview.lastError == "synthetic")
        #expect(m.preview.program?.pipeline.generation == landed.pipeline.generation)
        #expect(m.preview.program?.textures.count == landed.textures.count)
    }

    /// The two iPad requests (spec §22.3, §22.5) ride the same one-shot channel as ⌘⇧N, because
    /// the viewport's centre is a thing only the canvas view knows. Equatable and clearable, so a
    /// second ⌘V after the canvas consumed the first is a fresh request and not a no-op.
    @Test func pasteAndChooserRequestsRoundTripThroughCanvasRequest() {
        let m = model(RecordingCompiler())
        #expect(m.canvasRequest == nil)
        m.requestCanvas(.paste)
        #expect(m.canvasRequest == .paste)
        m.canvasRequest = nil
        m.requestCanvas(.openChooser)
        #expect(m.canvasRequest == .openChooser)
        m.canvasRequest = nil
        #expect(m.canvasRequest == nil)
    }
}
