# MetalNodes M6 — iPadOS UI Layer — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The existing multiplatform app becomes a full editor on iPadOS 27 — touch canvas, iPad layout, Photos/Files import, Files/Share export, hardware keyboard — while the three M5 carry-overs (atomic `PreviewState.program`, `DocumentBridge`, layer-parameter group variants) land first and an XCUITest target takes over the drag-and-drop checks.

**Architecture:** One `GraphCanvasView` on both platforms. On iOS a `TouchInputOverlay` (`UIViewRepresentable`) owns every canvas touch except the interactive rects node and comment views report by preference, translates UIKit recognizer callbacks into `TouchEvent`s, and a pure `TouchIntentMapper` turns those into `CanvasIntent`s the canvas applies through the same functions the mouse path calls. Platform services (`ImageChooser`, `Exporter`) are protocols with a Mac panel implementation, a Pad presenter implementation driven by SwiftUI's picker modifiers through a `PickerPresenter` continuation, and in-memory test doubles. The iPad layout is a `NavigationSplitView` with the palette as sidebar and the preview/inspector column as a trailing inspector.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 / iPadOS 27), UIKit gesture recognizers (iOS only), PhotosUI, Metal / MetalKit, Swift Testing, XCTest (UI tests), SwiftPM package `MetalNodesKit`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §2, §11.2, §11.3, §18.6 and **§22 (M6 addendum)**, which pins the mechanics. Read §22 in full before any task.

## Global Constraints

- Swift language mode `6`, strict concurrency, warning-free build (`swift build --package-path MetalNodesKit 2>&1 | grep -i warning` prints nothing).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics`. `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore`. `MetalNodesUI` may import AppKit only under `#if os(macOS)` in `*Mac.swift` files or gated sections, and UIKit / PhotosUI only under `#if os(iOS)` in `*Pad.swift` files or gated sections; UniformTypeIdentifiers and CoreTransferable are allowed anywhere in UI and the app.
- `MetalNodesUI` and `MetalNodesUITests` have `.defaultIsolation(MainActor.self)`; Core and Render do not. Anything SwiftUI calls off the main actor (`Shape.path`, `FileDocument`) is `nonisolated`.
- Colors only through `DraculaTheme` / `DraculaToken`; no hex outside `DraculaTheme.swift`. Red = errors only.
- Every document edit goes through `EditorModel.apply(_:)` on the active graph path; views never mutate `document`. Undo = whole-document snapshots in transactions; view state (`EditorViewState`) is never snapshotted or undone. `canvasMode` and `showsInspector` are view state.
- macOS behaviour is unchanged: every new platform branch is `#if os(iOS)`; the macOS regression subset in Task 11 must pass. Documents without textures, comments or groups generate byte-identical MSL to M5 (existing goldens unchanged); the fragment and preview programs are untouched by the layer variants.
- Node width stays `190`; `.dot` 24 × 24; culling/LOD unchanged. Touch thresholds: drag begins after 6 pt; tap ends inside 6 pt; long-press 0.4 s, cancelled by > 6 pt of movement.
- Tests: Swift Testing only in the package (goldens compared whole; under `#expect` compare against single typed literals); XCTest only in the `MetalNodesAppUITests` target. Package suite: `swift test --package-path MetalNodesKit`. App builds: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` **and** `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` — every task that touches `MetalNodesUI` or the app runs both. Xcode Cloud builds with **Xcode 26.6**; when a task's diff touches closures stored in views, also run the macOS build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (the Swift 6.2 IRGen crash of PR #7).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- `MetalNodes.xcodeproj/project.pbxproj` may change only in Task 10 (the `MetalNodesAppUITests` target), and Task 10 alone may add `MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme`; never commit key reorders beyond that or `xcuserdata/`. Opening the project through Xcode's MCP reorders the pbxproj — `git checkout -- MetalNodes.xcodeproj/project.pbxproj` before committing anything else.

---

## File structure

**Render** — Modify `PreviewState.swift` (`PreviewProgram`, `program`), `ShaderRenderer.swift` (T1).

**Core (`MetalNodesKit/Sources/MetalNodesCore`)**
- Modify `Persistence/ShaderPackage.swift` (`missingTextures` settable) (T2).
- Modify `Codegen/Validation.swift` (`reachableDefinitions`, delete the grouped-sample refusal), `Codegen/GroupCodegen.swift` (layer variants), `Codegen/EmitEnvironment.swift` (`usesLayer`, `.groupFunctionLayer`), `Codegen/Emitter.swift` (`layerFunctions`), `Codegen/ShaderGenerator.swift` (layer export assembly) (T3).
- Modify `EditorViewState.swift` (`canvasMode`, `showsInspector`) (T6).
- Modify `Library/StarterDocuments.swift` (`textured()` fixture) (T10).

**UI (`MetalNodesKit/Sources/MetalNodesUI`)**
- Modify `Editor/EditorModel.swift` (program publication, `textureSlots` computed) (T1). Create `Editor/DocumentBridge.swift` (T2).
- Create `Editor/PlatformServices.swift` (protocols, `PickedImage`, `ImageSource`, `ExportOutcome`, `EditorServices`, memory doubles), `Editor/EditorModel+Services.swift`; modify `Editor/ImagePanelMac.swift`, `Editor/ExportPanelMac.swift`, `Editor/EditorView.swift`, `Editor/InspectorView.swift`, `Canvas/ParamControl.swift` (T4).
- Create `Editor/PickerPresenter.swift`, `Editor/ExportDocuments.swift`, `Editor/ImageChooserPad.swift`, `Editor/ExporterPad.swift`; modify `Editor/EditorView.swift` (T5).
- Create `Canvas/TouchIntentMapper.swift` (T6); `CanvasMode` itself lives in Core's `EditorViewState.swift`.
- Create `Canvas/InteractiveRect.swift`, `Canvas/TouchInputOverlayPad.swift`; modify `Canvas/GraphCanvasView.swift`, `Canvas/NodeView.swift`, `Canvas/SocketView.swift`, `Canvas/CommentLayer.swift`, `Canvas/StickyView.swift`, `Canvas/FrameView.swift` (T7).
- Create `Editor/CanvasContextMenu.swift`, `Editor/EditorViewPad.swift`; modify `Editor/EditorView.swift`, `Editor/EditorModel.swift` (`CanvasRequest.paste`, `.openChooser`), `Canvas/GraphCanvasView.swift`, `Palette/PaletteView.swift` (T8).
- Modify `Editor/EditorCommands.swift`, `Palette/NodeSearchPopover.swift` (T9).

**App (`MetalNodes/`)** — Modify `DocumentHostView.swift` (bridge) (T2), (`Open Sample Shader` toolbar item on iOS) (T8), `MetalNodesApp.swift` (`-mnFixture`) (T10). Create `MetalNodesAppUITests/` (T10).

**Tests** — Render: additions to `PreviewStateTests` (new); UI: `EditorModelTests` (updated), `DocumentBridgeTests`, `EditorServicesTests`, `PickerPresenterTests`, `ExportDocumentsTests`, `TouchIntentMapperTests`; Core: `TextureCodegenTests` (updated), `LayerVariantTests`, `EditorViewStateTests` (new); App: `MetalNodesAppUITests` (XCTest).

---

### Task 1: `PreviewState.program` — pipeline and bindings published together

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift:29-33, 65-69`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift:98-101, 163-180, 461-486`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Assets.swift:99-101` (unchanged call, verify)
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift` (create), `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift:322-360`

**Interfaces:**
- Produces: `public struct PreviewProgram { let pipeline: CompiledPipeline; let textures: [Int: MTLTexture] }`; `PreviewState.program: PreviewProgram?`; `PreviewState.pipeline: CompiledPipeline?` (computed, read-only); `EditorModel.textureSlots: [TextureSlot]` (computed). `PreviewState.textures` is deleted.

- [ ] **Step 1: Write the failing Render test**

`MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift`:

```swift
import Testing
import Metal
import MetalNodesCore
@testable import MetalNodesRender

@MainActor
@Suite struct PreviewStateTests {
    @Test func pipelineMirrorsTheProgram() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice(), "No Metal device — this test needs a GPU")
        let compiler = try ShaderCompiler(device: device)
        let shader = try ShaderGenerator.generate(.starter(), registry: .builtin)
        guard case .success(let pipeline) = await compiler.compile(shader, generation: 1, fastMath: true) else {
            Issue.record("starter did not compile"); return
        }
        let state = PreviewState()
        #expect(state.pipeline == nil)
        state.program = PreviewProgram(pipeline: pipeline, textures: [:])
        #expect(state.pipeline?.generation == 1)
        #expect(state.program?.textures.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter PreviewStateTests`
Expected: FAIL — `PreviewProgram` / `program` do not exist.

- [ ] **Step 3: Replace the two properties with one program**

`PreviewState.swift` — replace `pipeline` and `textures`:

```swift
/// The pipeline that is drawing and the textures its slots bind, published as one value so the
/// renderer can never see a pipeline with another program's bindings (spec §22.6).
public struct PreviewProgram {
    public let pipeline: CompiledPipeline
    /// Slot index → texture, one entry per `pipeline.shader.textures` slot.
    public let textures: [Int: MTLTexture]
    public init(pipeline: CompiledPipeline, textures: [Int: MTLTexture]) {
        self.pipeline = pipeline; self.textures = textures
    }
}

@MainActor
@Observable
public final class PreviewState {
    public var program: PreviewProgram?
    /// The live pipeline, for readers that only need it (the preview pane's generation label).
    public var pipeline: CompiledPipeline? { program?.pipeline }
    public var uniforms: UniformImage?
    // … the remaining properties are unchanged …
```

`ShaderRenderer.draw(in:)`:

```swift
        guard let program = state.program, var image = state.uniforms,
              image.layout == program.pipeline.shader.layout,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }
        // …
        enc.setRenderPipelineState(program.pipeline.state)
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        for (index, texture) in program.textures {
            enc.setFragmentTexture(texture, index: index)
        }
```

- [ ] **Step 4: Publish from `EditorModel` atomically**

`EditorModel.swift` — delete the stored `textureSlots` and `rebindTextures()`; replace with:

```swift
    /// The slots of the live pipeline. Read by the tests and by the missing-texture diagnostics.
    var textureSlots: [TextureSlot] { preview.program?.pipeline.shader.textures ?? [] }

    /// Publishes `pipeline` together with the bindings its slots need — one write, so the renderer
    /// never draws a pipeline against another program's textures (spec §22.6).
    private func publish(_ pipeline: CompiledPipeline) {
        preview.program = PreviewProgram(pipeline: pipeline, textures: bindings(for: pipeline))
    }

    /// Rebuilds the live program's bindings — called whenever the bytes or the manifest change
    /// (spec §21.2). Keys off the pipeline that is drawing: a compile failure leaves the last-good
    /// pipeline live, and binding a *new* program's slots could leave one of its `tex<i>` unbound.
    func refreshTextureBindings() {
        guard let pipeline = preview.program?.pipeline else { return }
        preview.program = PreviewProgram(pipeline: pipeline, textures: bindings(for: pipeline))
    }

    private func bindings(for pipeline: CompiledPipeline) -> [Int: MTLTexture] {
        textureStore?.bindings(for: pipeline.shader.textures, textures: textures) ?? [:]
    }
```

In `compileNow`: the `lastCompiled` reuse branch keeps `if last.succeeded, let p = preview.pipeline { … refreshTextureBindings() }` (replace the `rebindTextures()` call); the `.success` branch becomes:

```swift
        case .success(let pipeline):
            guard pipeline.generation == generation else { return }
            publish(pipeline)
            preview.uniforms = UniformImage.rebuild(layout: pipeline.shader.layout, document: document, registry: registry)
            preview.lastError = nil
            lastCompiled = (shader.source, doc.settings.fastMath, true)
```

`import Metal` at the top of `EditorModel.swift` (for `MTLTexture`). Grep the package for `preview.textures` and `.pipeline =` and fix every remaining reader/writer (`EditorView` reads `model.preview.pipeline?.generation` — unchanged).

- [ ] **Step 5: Update `textureBindingsFollowTheLivePipeline` and add the atomicity test**

In `EditorModelTests.swift` replace every `m.preview.textures.count` with `m.preview.program?.textures.count` (`== 1` becomes `== 1`, `.isEmpty` becomes `m.preview.program?.textures.isEmpty == true`) and append:

```swift
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
```

- [ ] **Step 6: Run the suites, both app builds, commit**

Run: `swift test --package-path MetalNodesKit` → all green. Both `xcodebuild` commands from Global Constraints → `BUILD SUCCEEDED`.

```bash
git add MetalNodesKit
git commit -m "refactor(render): PreviewState publishes pipeline and texture bindings as one program"
```

---

### Task 2: `DocumentBridge` and `reachableDefinitions`-free host

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Persistence/ShaderPackage.swift:32` (`public var missingTextures`)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/DocumentBridge.swift`
- Modify: `MetalNodes/DocumentHostView.swift`
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §22.6 (one sentence, see Step 4)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/DocumentBridgeTests.swift` (create)

**Interfaces:**
- Consumes: `EditorModel.package`, `EditorModel.reload(package:)`, `EditorModel.missingTextures`.
- Produces: `public final class DocumentBridge { init(model:); var package: ShaderPackage { get }; func mirror(into: inout ShaderPackage) -> Bool; func apply(_ package: ShaderPackage) -> Bool }`.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

@MainActor
@Suite struct DocumentBridgeTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .starter(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    @Test func packageCarriesTheMissingSet() {
        let m = model()
        let a = AssetID()
        m.missingTextures = [a]
        let bridge = DocumentBridge(model: m)
        #expect(bridge.package.missingTextures == [a])
        #expect(bridge.package.document == m.document)
    }

    @Test func mirrorWritesOnlyWhatDiffers() {
        let m = model()
        let bridge = DocumentBridge(model: m)
        var file = bridge.package
        #expect(bridge.mirror(into: &file) == false)          // already equal: nothing written
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        m.apply(.moveNodes([uv.id: CGPoint(x: 9, y: 9)]))
        #expect(bridge.mirror(into: &file) == true)
        #expect(file.document == m.document)
        #expect(file.viewState == m.viewState)
    }

    @Test func applyIsANoOpForThePackageTheModelAlreadyHolds() {
        let m = model()
        let bridge = DocumentBridge(model: m)
        let before = m.undoStackVersion
        #expect(bridge.apply(bridge.package) == false)
        #expect(m.undoStackVersion == before)
    }

    @Test func applyReloadsAnExternalChangeAndDropsUndo() async {
        let m = model()
        let bridge = DocumentBridge(model: m)
        let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        m.apply(.moveNodes([uv.id: CGPoint(x: 9, y: 9)]))
        #expect(m.canUndo)
        var incoming = bridge.package
        incoming.document.root.nodes[uv.id]?.position = CGPoint(x: 1, y: 2)
        #expect(bridge.apply(incoming) == true)
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 1, y: 2))
        #expect(!m.canUndo)
        await m.awaitIdle()
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter DocumentBridgeTests` → FAIL, `DocumentBridge` undefined.

- [ ] **Step 3: Implement**

`ShaderPackage.swift`: change `public private(set) var missingTextures` to `public var missingTextures: Set<AssetID> = []`.

`DocumentBridge.swift`:

```swift
import Foundation
import MetalNodesCore

/// The model ↔ file mirror, out of the window (spec §22.6). The host owns a `FileDocument` it
/// cannot show this module; the bridge owns everything about *when* a field moves between the two,
/// so both directions are unit-testable without a window.
@MainActor
public final class DocumentBridge {
    public let model: EditorModel

    public init(model: EditorModel) { self.model = model }

    /// Everything the package holds, from the model's live state — `missingTextures` included, so a
    /// reseed from this package re-imposes the same missing set the model has now.
    public var package: ShaderPackage {
        var p = model.package
        p.missingTextures = model.missingTextures
        return p
    }

    /// Model → file. Writes each field only when it differs, so a value that arrived *from* the
    /// file is never written back (which would mark the window dirty for nothing). True if anything
    /// was written.
    @discardableResult
    public func mirror(into file: inout ShaderPackage) -> Bool {
        var wrote = false
        if file.document != model.document { file.document = model.document; wrote = true }
        if file.viewState != model.viewState { file.viewState = model.viewState; wrote = true }
        if file.textures != model.textures { file.textures = model.textures; wrote = true }
        if file.missingTextures != model.missingTextures { file.missingTextures = model.missingTextures; wrote = true }
        return wrote
    }

    /// File → model. A no-op for a package equal to what the model already holds (the mirror's own
    /// writes come back through here); anything else is an external change — File ▸ Revert To Saved
    /// — and reseeds the model, undo stack and all. True if it reloaded.
    @discardableResult
    public func apply(_ incoming: ShaderPackage) -> Bool {
        guard incoming.document != model.document
                || incoming.viewState != model.viewState
                || incoming.textures != model.textures else { return false }
        model.reload(package: incoming)
        return true
    }
}
```

`DocumentHostView.swift` — replace the `@State private var model` with `@State private var bridge: DocumentBridge?` and the body's mirror with:

```swift
            if let bridge {
                EditorView(model: bridge.model, device: device)
                    // Model → file: the three observable fields the bridge mirrors. Keyed on
                    // `texturesVersion`, not the bytes (spec §21.2).
                    .onChange(of: bridge.model.document) { _, _ in bridge.mirror(into: &file.package) }
                    .onChange(of: bridge.model.viewState) { _, _ in bridge.mirror(into: &file.package) }
                    .onChange(of: bridge.model.texturesVersion) { _, _ in bridge.mirror(into: &file.package) }
                    // File → model: the bridge decides whether this is an external change.
                    .onChange(of: file.package) { _, incoming in bridge.apply(incoming) }
            } else {
                Color.clear.onAppear(perform: makeModel)
            }
```

`makeModel` ends with `bridge = DocumentBridge(model: m)`; the undo-manager `onChange` uses `bridge?.model`. Delete `reseed()`. Keep `.frame(minWidth: 960, minHeight: 620)` under `#if os(macOS)` (an iPad window is sized by the system).

- [ ] **Step 4: Spec line**

In §22.6 replace "`var version: Int` bumped on every model change that must reach the file. `DocumentHostView` (shared by both platforms, no `#if`) watches `bridge.version` and writes `file.package = bridge.package`, and watches `file.package` and calls `bridge.apply`." with "`func mirror(into: inout ShaderPackage) -> Bool` writes only the fields that differ. `DocumentHostView` (shared by both platforms) calls `mirror` from `onChange` of the model's `document`, `viewState` and `texturesVersion`, and `apply` from `onChange` of the file's package."

- [ ] **Step 5: Run, build both platforms, commit**

`swift test --package-path MetalNodesKit` green; both `xcodebuild`s succeed.

```bash
git add MetalNodesKit MetalNodes docs
git commit -m "refactor(ui): DocumentBridge owns the model↔file mirror; host is a thin wrapper"
```

---
### Task 3: Layer-parameter group variants

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift:12, 21-30, 48-50, 65-69`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/GroupCodegen.swift:30-40, 73-75, 86-88, 99, 110, 122-125`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift:51-55, 220-227`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift:105-107, 158-171, 191`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift:24, 29-62`
- Read only, unchanged: `MetalNodesKit/Sources/MetalNodesCore/Groups/GroupDependencies.swift` (`reachable`, `innerFirst` already give everything the variants need)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LayerVariantTests.swift` (create), `MetalNodesKit/Tests/MetalNodesCoreTests/TextureCodegenTests.swift:81-89` (delete `layerEffectRefusesATextureSampleInsideAGroup`), `:111-124` (rewrite `layerEffectIgnoresATextureSampleInAnUninstantiatedDefinition`)

**Interfaces:**
- Consumes: `GroupDependencies.reachable(from:in:)`, `GroupDependencies.innerFirst(_:in:)`, `TextureSlot.parameterName` / `.fragmentName`, `GroupCodegen.functionName(_:)`, `GroupCodegen.structName(_:)`, `StitchableCodegen.signature(kind:name:args:textures:forExport:)`.
- Produces:
  - `public var EmitEnvironment.usesLayer: Bool` (stored, init parameter `usesLayer: Bool = false` appended after `textureName:`); `public static let EmitEnvironment.groupFunctionLayer: EmitEnvironment`; `EmitEnvironment.layerExport` gains `usesLayer: true`.
  - `public let GroupFunction.isLayerVariant: Bool` (init parameter `isLayerVariant: Bool = false`, last).
  - `static func GroupCodegen.function(for:document:registry:functions:view:layer:layerFunctions:) throws(GenerationError) -> GroupFunction` — new trailing `layer: Bool = false, layerFunctions: [GroupID: GroupFunction] = [:]`.
  - `static func Emitter.emit(order:graph:path:document:registry:resolved:env:reserved:functions:viewInstance:layerFunctions:) -> Output` — new trailing `layerFunctions: [GroupID: GroupFunction] = [:]`.
  - `public static func GraphValidator.reachableDefinitions(_ doc: ShaderDocument) -> [GroupDefinition]` (sorted by id).
  - `ShaderGenerator.assembleStitchable` gains `groupOrder: [GroupID]` and becomes `throws(GenerationError)` (private; no public change).
- Deleted: the diagnostic message `"Texture Sample inside a group needs the Fragment target"` and the whole `.layerEffect` branch of `textureTargetDiagnostics`.

**Byte-identical guarantee:** nothing in this task touches `assembleFragment`, `fragmentProgram`, `fragmentSignature`, `StitchableCodegen` or the *preview* half of `assembleStitchable`. `groupFunctionLayer`/`layerExport` are only reachable from the Layer-Effect **export** builder; every other program keeps `.fragment` / `.groupFunction` / `.stitchableFunction`, whose emission is unchanged (`usesLayer` is `false` there, so the `.group` call site takes the same `else` branch it takes today). `layerFunctions` is empty for the Fragment, Color Effect and Distortion Effect targets, so `exportFunctions == groupFunctions` and the export builder emits the same bytes. `TextureCodegenTests.documentsWithoutTexturesAreUnchanged`, `FragmentExportTests.fragmentHeaderGoldenForATexturedDocument`, `ShaderExportTests.swiftSnippetGoldenForColorEffect`, `GroupCodegenTests`, `LineMapGroupTests` and `ViewerCodegenTests` must all still pass untouched — the suite in Step 6 is the check.

- [ ] **Step 1: Write the failing tests**

`MetalNodesKit/Tests/MetalNodesCoreTests/LayerVariantTests.swift` (create):

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// Layer-parameter group variants (spec §22.7): under the Layer Effect **export**, a definition
/// whose transitive body samples gets a second `…_layer` function that reads SwiftUI's `Layer`
/// instead of a `texture2d<float>` parameter. The fragment and preview programs are untouched.
@Suite struct LayerVariantTests {
    let reg = NodeRegistry.builtin
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func gid(_ n: Int) -> GroupID { GroupID(raw: UUID(uuidString: String(format: "1000000%d-0000-0000-0000-000000000000", n))!) }
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    /// Definition “Tex” (`gid(1)`): one Texture Sample of asset 2 → Group Output. Instantiated once
    /// in a root that is nothing but that instance and the Fragment Output. Every id is fixed, so
    /// the whole export is reproducible and can be compared as one string. The group ids differ in
    /// their *first* eight hex digits, because that prefix is what names the MSL struct.
    private func sampling() -> ShaderDocument {
        var def = GroupDefinition(id: gid(1), name: "Tex", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(10), kind: .groupInput)
        let gout = NodeInstance(id: id(11), kind: .groupOutput)
        let sample = NodeInstance(id: id(12), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        for n in [gin, gout, sample] { def.graph.nodes[n.id] = n }
        def.graph.connect(SocketRef(sample.id, "color"), to: SocketRef(gout.id, "color"))

        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let inst = NodeInstance(id: id(1), kind: .group(def.id))
        let out = NodeInstance(id: id(2), kind: .builtin("output.fragment"))
        d.root.nodes[inst.id] = inst; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(inst.id, "color"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"
        return d
    }

    /// “Outer” (`gid(3)`) samples nothing itself: it only instantiates “Tex”. The root instantiates
    /// “Outer”. Containment is transitive, so both get a `_layer` variant.
    private func nested() -> ShaderDocument {
        var d = sampling()
        var outer = GroupDefinition(id: gid(3), name: "Outer", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(20), kind: .groupInput)
        let gout = NodeInstance(id: id(21), kind: .groupOutput)
        let inner = NodeInstance(id: id(22), kind: .group(gid(1)))
        for n in [gin, gout, inner] { outer.graph.nodes[n.id] = n }
        outer.graph.connect(SocketRef(inner.id, "color"), to: SocketRef(gout.id, "color"))
        d.definitions[outer.id] = outer
        d.root.remove(node: id(1))
        let oi = NodeInstance(id: id(3), kind: .group(outer.id))
        d.root.nodes[oi.id] = oi
        d.root.connect(SocketRef(oi.id, "color"), to: SocketRef(id(2), "color"))
        return d
    }

    @Test func groupedSampleExportsALayerVariant() throws {
        let s = try ShaderGenerator.generate(sampling(), target: .stitchable(.layerEffect), registry: reg)
        let expected = """
        #include <metal_stdlib>
        #include <SwiftUI/SwiftUI_Metal.h>
        using namespace metal;

        constexpr sampler mn_sampler(filter::linear, address::repeat);

        struct G_10000001_Out {
            float4 color;
        };

        G_10000001_Out mn_g_Tex_10000001_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            float4 v0;
            float v1;
            float4 v0_s = float4(layer.sample(position));
            v0 = v0_s;
            v1 = v0_s.w;
            G_10000001_Out out;
            out.color = v0;
            return out;
        }

        [[stitchable]] half4 fx(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            G_10000001_Out r0 = mn_g_Tex_10000001_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            return half4(v1);
        }

        """
        #expect(s.exportSource == expected)
    }

    @Test func theExportBindsNothingWhileThePreviewStillBindsTheAsset() throws {
        let s = try ShaderGenerator.generate(sampling(), target: .stitchable(.layerEffect), registry: reg)
        #expect(s.textures == [TextureSlot(index: 0, asset: aid(2))])
        #expect(!s.exportSource!.contains("texture2d"))
        #expect(!s.exportSource!.contains("tex0"))
        #expect(s.source.contains("texture2d<float> tex0 [[texture(0)]]"))
        #expect(s.source.contains("mn_g_Tex_10000001(float2 uv, float time, float2 size, float2 mouse, texture2d<float> t_20000000)"))
        #expect(s.source.contains("mn_g_Tex_10000001(uv, time, size, mouse, tex0)"))
        #expect(!s.source.contains("_layer"))
    }

    @Test func nestedDefinitionsGetLayerVariantsTransitively() throws {
        let s = try ShaderGenerator.generate(nested(), target: .stitchable(.layerEffect), registry: reg)
        let expected = """
        #include <metal_stdlib>
        #include <SwiftUI/SwiftUI_Metal.h>
        using namespace metal;

        constexpr sampler mn_sampler(filter::linear, address::repeat);

        struct G_10000001_Out {
            float4 color;
        };

        G_10000001_Out mn_g_Tex_10000001_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            float4 v0;
            float v1;
            float4 v0_s = float4(layer.sample(position));
            v0 = v0_s;
            v1 = v0_s.w;
            G_10000001_Out out;
            out.color = v0;
            return out;
        }

        struct G_10000003_Out {
            float4 color;
        };

        G_10000003_Out mn_g_Outer_10000003_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            G_10000001_Out r0 = mn_g_Tex_10000001_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            G_10000003_Out out;
            out.color = v1;
            return out;
        }

        [[stitchable]] half4 fx(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            G_10000003_Out r0 = mn_g_Outer_10000003_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            return half4(v1);
        }

        """
        #expect(s.exportSource == expected)
    }

    /// A definition that samples nothing needs no second function: the export emits it once, under
    /// its ordinary name, even though the root itself samples the layer.
    @Test func aDefinitionWithoutASampleKeepsOneFunction() throws {
        var def = GroupDefinition(id: gid(5), name: "Half",
                                  inputs: [SocketDecl(name: "a", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))))],
                                  outputs: [SocketDecl(name: "out", type: .concrete(.color))])
        let gin = NodeInstance(id: id(30), kind: .groupInput)
        let gout = NodeInstance(id: id(31), kind: .groupOutput)
        for n in [gin, gout] { def.graph.nodes[n.id] = n }
        def.graph.connect(SocketRef(gin.id, "a"), to: SocketRef(gout.id, "out"))

        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let sample = NodeInstance(id: id(4), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        let inst = NodeInstance(id: id(5), kind: .group(def.id))
        let out = NodeInstance(id: id(6), kind: .builtin("output.fragment"))
        for n in [sample, inst, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(sample.id, "color"), to: SocketRef(inst.id, "a"))
        d.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"

        let s = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
        let export = try #require(s.exportSource)
        #expect(!export.contains("_layer"))
        #expect(export.components(separatedBy: "mn_g_Half_10000005").count == 3)   // one definition, one call
        #expect(export.contains("float4(layer.sample(position))"))                 // the root's own sample
        #expect(!export.contains("texture2d"))
    }

    /// Only the definitions the root's program emits, sorted by id (spec §22.6).
    @Test func reachableDefinitionsListsWhatTheRootInstantiates() throws {
        var d = nested()
        var stray = GroupDefinition(id: gid(7), name: "Stray", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(40), kind: .groupInput)
        let gout = NodeInstance(id: id(41), kind: .groupOutput)
        for n in [gin, gout] { stray.graph.nodes[n.id] = n }
        d.definitions[stray.id] = stray
        #expect(GraphValidator.reachableDefinitions(d).map(\.id) == [gid(1), gid(3)])
        #expect(GraphValidator.reachableDefinitions(ShaderDocument.sample()).isEmpty)
    }

    /// The Layer Effect export with a grouped sample must be a valid Metal file — `SwiftUI::Layer`
    /// comes from `#include <SwiftUI/SwiftUI_Metal.h>`, which the macOS SDK provides. `xcrun metal`
    /// is not always installed; skip silently when it is not (probe copied from `FragmentExportTests`).
    @Test func theLayerExportCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        for d in [sampling(), nested()] {
            let files = try ShaderExport.files(for: d, registry: reg)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-layer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(files[0].name)
            try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
            let metal = Process()
            metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
            let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
            try metal.run(); metal.waitUntilExit()
            let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(metal.terminationStatus == 0, "\(d.definitions.count) definitions: \(log)")
        }
    }
}
```

In `TextureCodegenTests.swift` **delete** `layerEffectRefusesATextureSampleInsideAGroup` in full — lines 81-89, from `@Test func layerEffectRefusesATextureSampleInsideAGroup() throws {` down to and including its closing `}` and the blank line after it:

```swift
    @Test func layerEffectRefusesATextureSampleInsideAGroup() throws {
        // The export has only `layer`, which cannot bind to the group function's `texture2d<float>`
        // parameter — so the Layer Effect refuses a grouped sample even though it allows a root one.
        var (d, sample) = groupDoc()
        d.settings.target = .stitchable(.layerEffect)
        let diags = GraphValidator.validate(document: d, registry: reg, target: d.settings.target)
        #expect(diags.contains { $0.message == "Texture Sample inside a group needs the Fragment target" && $0.node == sample })
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(d, target: d.settings.target, registry: reg) }
    }
```

and **replace** `layerEffectIgnoresATextureSampleInAnUninstantiatedDefinition` (lines 111-124, the doc comment above it included) with a version that names no deleted message. Old:

```swift
    /// Ungroup leaves the definition in My Functions with no instance. Nothing exports it, so the
    /// Layer Effect has no quarrel with the sample inside it — the document must still generate.
    @Test func layerEffectIgnoresATextureSampleInAnUninstantiatedDefinition() throws {
        var (d, sample) = groupDoc()
        let gid = d.definitions.keys.first!
        for n in d.root.nodes.values where n.kind == .group(gid) { d.root.remove(node: n.id) }
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"
        let message = "Texture Sample inside a group needs the Fragment target"
        let diags = GraphValidator.validate(document: d, registry: reg, target: d.settings.target)
        #expect(!diags.contains { $0.message == message })
        #expect(!diags.contains { $0.node == sample })
        #expect(throws: Never.self) { try ShaderGenerator.generate(d, target: d.settings.target, registry: reg) }
    }
```

New:

```swift
    /// Ungroup leaves the definition in My Functions with no instance. Nothing exports it, so its
    /// Texture Sample reaches no program: no diagnostic, no slot, and no `_layer` variant — the
    /// Layer Effect's grouped-sample refusal is gone entirely (spec §22.7).
    @Test func layerEffectIgnoresATextureSampleInAnUninstantiatedDefinition() throws {
        var (d, sample) = groupDoc()
        let gid = d.definitions.keys.first!
        for n in d.root.nodes.values where n.kind == .group(gid) { d.root.remove(node: n.id) }
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"
        let diags = GraphValidator.validate(document: d, registry: reg, target: d.settings.target)
        #expect(!diags.contains { $0.node == sample })
        #expect(GraphValidator.reachableDefinitions(d).isEmpty)
        let s = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
        #expect(s.textures.isEmpty)
        #expect(s.exportSource?.contains("_layer") == false)
    }
```

Leave `colorEffectRefusesTextureSampleAndLayerEffectSamplesTheLayer`, `colorEffectIgnoresATextureSampleInAnUninstantiatedDefinition`, `colorEffectReportsTheTargetRefusalOnce` and `groupFunctionsTakeTextureParameters` exactly as they are — they still pass.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter 'LayerVariantTests|TextureCodegenTests'`
Expected: FAIL to **build** — `GraphValidator.reachableDefinitions` is undefined (used by two tests). After it exists the golden tests would still fail: today the export emits `mn_g_Tex_10000001(float2 uv, …, texture2d<float> t_20000000)` and the call site passes `layer` for that parameter.

- [ ] **Step 3: `EmitEnvironment.usesLayer` and `.groupFunctionLayer`**

`EmitEnvironment.swift` — add the stored property after `textureName` (line 12):

```swift
    /// How a *call site* in this program spells a slot it passes to a group function.
    public var textureName: @Sendable (TextureSlot) -> String
    /// True in the two environments that sample a SwiftUI `Layer` instead of a bound texture.
    public var usesLayer: Bool
```

Extend the initializer (lines 21-30):

```swift
    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: String],
                textureSample: @escaping @Sendable (TextureSlot, String) -> String
                    = { slot, uv in EmitEnvironment.flippedSample(slot.fragmentName, uv) },
                textureName: @escaping @Sendable (TextureSlot) -> String = { $0.fragmentName },
                usesLayer: Bool = false) {
        self.uniform = uniform
        self.sys = sys
        self.textureSample = textureSample
        self.textureName = textureName
        self.usesLayer = usesLayer
    }
```

Add `groupFunctionLayer` immediately after `groupFunction` (which ends at line 42 with `textureName: { $0.parameterName })`):

```swift
    /// Inside a group function's **layer variant** (spec §22.7): the definition takes no texture
    /// parameter at all — every Texture Sample reads the `SwiftUI::Layer` the caller passes down,
    /// at the caller's `position`, exactly as the exported root function does.
    public static let groupFunctionLayer = EmitEnvironment(
        uniform: groupFunction.uniform,
        sys: groupFunction.sys,
        textureSample: { _, _ in "float4(layer.sample(position))" },
        textureName: { _ in "layer" },
        usesLayer: true)
```

and mark `layerExport` (lines 65-69) as a layer environment:

```swift
    public static let layerExport = EmitEnvironment(
        uniform: stitchableFunction.uniform,
        sys: stitchableFunction.sys,
        textureSample: { _, _ in "float4(layer.sample(position))" },
        textureName: { _ in "layer" },
        usesLayer: true)
```

- [ ] **Step 4: `GroupCodegen` emits the `_layer` variant**

`GroupCodegen.swift` — add the flag to `GroupFunction` (after `resolved`, line 30) and to its initializer:

```swift
    /// Every node of the definition's graph, typed. `GeneratedShader.resolved` merges these in, so
    /// the editor knows a socket's real type while dived into a definition (ruling R20).
    public let resolved: [NodeID: ResolvedNode]
    /// True for the `…_layer` variant emitted for the Layer Effect export (spec §22.7). Its
    /// `textureParams` still lists what the body samples — that is how a caller knows to call it —
    /// but its signature takes `SwiftUI::Layer layer, float2 position` instead of those textures.
    public let isLayerVariant: Bool

    init(id: GroupID, name: String, structName: String, inputs: [SocketDecl], outputs: [SocketDecl],
         uniformParams: [(path: ParamPath, type: SocketType)], textureParams: [TextureSlot] = [],
         requiredStdlib: [String], source: String,
         lineMap: LineMap, viewedType: SocketType? = nil, resolved: [NodeID: ResolvedNode] = [:],
         isLayerVariant: Bool = false) {
        self.id = id; self.name = name; self.structName = structName
        self.inputs = inputs; self.outputs = outputs; self.uniformParams = uniformParams
        self.textureParams = textureParams
        self.requiredStdlib = requiredStdlib; self.source = source
        self.lineMap = lineMap; self.viewedType = viewedType; self.resolved = resolved
        self.isLayerVariant = isLayerVariant
    }
```

Extend the signature of `function(for:…)` (lines 73-74) and its doc comment:

```swift
    /// Emits `def`'s function. `functions` must already hold every definition `def` instantiates.
    /// With `view`, emits the definition's **view variant** instead: named `…_view`, its single
    /// output `value` is the viewed socket and its body is emitted from that socket's node.
    /// With `layer`, emits the definition's **layer variant**: named `…_layer`, it takes
    /// `SwiftUI::Layer layer, float2 position` in place of its texture parameters and its samples
    /// read the layer (spec §22.7). `layerFunctions` must already hold the layer variant of every
    /// sampling definition `def` instantiates, so nested calls resolve to variants too.
    static func function(for def: GroupDefinition, document doc: ShaderDocument, registry: NodeRegistry,
                         functions: [GroupID: GroupFunction], view: ViewOutput? = nil,
                         layer: Bool = false, layerFunctions: [GroupID: GroupFunction] = [:]) throws(GenerationError) -> GroupFunction {
```

Pick the environment and forward the variants at the `Emitter.emit` call (lines 86-88):

```swift
        let emitted = Emitter.emit(order: order, graph: def.graph, path: path, document: doc, registry: registry,
                                   resolved: resolved, env: layer ? .groupFunctionLayer : .groupFunction,
                                   reserved: [], functions: functions,
                                   viewInstance: view.flatMap { v in v.innerVariant.map { (id: v.socket.node, function: $0) } },
                                   layerFunctions: layerFunctions)
```

Suffix the name (line 99) — the struct name is deliberately *not* suffixed, so both variants of a definition return the same `G_<8hex>_Out` and a caller can mix them:

```swift
        let fnName = functionName(def) + (viewed == nil ? "" : "_view") + (layer ? "_layer" : "")
```

Swap the trailing parameters (line 110):

```swift
        params += emitted.uniformRequests.map { "\($0.type.mslName) \(parameterName(for: $0.path))" }
        params += layer ? ["SwiftUI::Layer layer", "float2 position"]
                        : emitted.textureRequests.map { "texture2d<float> \($0.parameterName)" }
        b.add("\(outStruct) \(fnName)(\(params.joined(separator: ", "))) {")
```

and record the flag on the way out (line 122-125):

```swift
        return GroupFunction(id: def.id, name: fnName, structName: outStruct, inputs: def.inputs, outputs: outputs,
                             uniformParams: emitted.uniformRequests, textureParams: emitted.textureRequests,
                             requiredStdlib: emitted.requiredStdlib,
                             source: b.text, lineMap: b.map, viewedType: viewed?.type, resolved: resolved,
                             isLayerVariant: layer)
```

- [ ] **Step 5: `Emitter` calls the variant at a sampling call site**

`Emitter.swift` — add the parameter (lines 51-55):

```swift
                     functions: [GroupID: GroupFunction] = [:],
                     viewInstance: (id: NodeID, function: GroupFunction)? = nil,
                     layerFunctions: [GroupID: GroupFunction] = [:]) -> Output {
```

In pass 2's `case .group(let gid):`, replace the two lines that append the texture arguments and the call statement (lines 225-226) with the branch. Surrounding context, unchanged above and below:

```swift
                args += fn.inputs.map { inputs[$0.name] ?? GroupCodegen.zeroLiteral(r.inputTypes[$0.name] ?? .float) }
                args += fn.uniformParams.map { uniformExpr($0.path) }
                // A program that samples the layer has no texture to pass: it calls the callee's
                // layer variant and hands down its own `layer` and `position` (spec §22.7).
                let callee: GroupFunction
                if env.usesLayer, !fn.textureParams.isEmpty, let variant = layerFunctions[gid] {
                    callee = variant
                    args += ["layer", "position"]
                } else {
                    callee = fn
                    // The function names its texture parameters by asset; this program spells the
                    // same assets by its own slots (spec §21.2).
                    args += fn.textureParams.map { env.textureName(textureSlots[$0.asset]!) }
                }
                out.bodyLines.append("\(callee.structName) \(result) = \(callee.name)(\(args.joined(separator: ", ")));")
                out.lineOwners.append(id)
                if let viewed = fn.viewedType {
```

Pass 1 is untouched: a `.group` instance still requests the slots its (normal) function names, so a definition's samples keep propagating into the *preview*'s `textureRequests` and the manifest/binding path is unchanged. The layer emission's own `textureRequests` are simply discarded by the export builder.

- [ ] **Step 6: `ShaderGenerator` builds the variants for the Layer Effect export**

`ShaderGenerator.swift` — pass `groupOrder` down and propagate the throw (lines 105-107):

```swift
        case .stitchable(let kind):
            return try assembleStitchable(doc, kind: kind, order: order, terminal: terminal, resolved: resolved, registry: registry,
                                          functions: functions, groupOrder: groupOrder, groupFunctions: groupFunctions)
```

Change `assembleStitchable`'s signature (lines 158-160):

```swift
    private static func assembleStitchable(_ doc: ShaderDocument, kind: StitchableKind, order: [NodeID], terminal: NodeID,
                                           resolved: [NodeID: ResolvedNode], registry: NodeRegistry,
                                           functions: [GroupID: GroupFunction], groupOrder: [GroupID],
                                           groupFunctions: [GroupFunction]) throws(GenerationError) -> GeneratedShader {
```

and replace the `exported` computation (lines 166-171) with the variant build plus the export's own function list:

```swift
        let textures = emitted.textureRequests
        // The preview binds the assets as textures; the export has none to bind and reads the layer
        // SwiftUI passes instead, so it needs its own emission (spec §21.2).
        //
        // Every reachable definition whose *transitive* body samples gets a `_layer` variant —
        // `textureParams` already carries containment transitively, so a definition that only
        // instantiates a sampling one is in this list too. `groupOrder` is inner-first, so each
        // variant is built after the variants it calls and can name them (spec §22.7).
        var layerFunctions: [GroupID: GroupFunction] = [:]
        if kind == .layerEffect, !textures.isEmpty {
            for gid in groupOrder where !(functions[gid]?.textureParams.isEmpty ?? true) {
                layerFunctions[gid] = try GroupCodegen.function(for: doc.definitions[gid]!, document: doc, registry: registry,
                                                                functions: functions, layer: true, layerFunctions: layerFunctions)
            }
        }
        /// What the export splices in: the layer variant where there is one, the normal function
        /// otherwise. Identical to `groupFunctions` for every target but the Layer Effect.
        let exportFunctions = groupOrder.compactMap { layerFunctions[$0] ?? functions[$0] }
        let exported = textures.isEmpty ? emitted
            : Emitter.emit(order: order, graph: doc.root, path: .root, document: doc, registry: registry,
                           resolved: resolved, env: .layerExport, functions: functions,
                           layerFunctions: layerFunctions)
```

Finally, the export builder splices those functions instead of `groupFunctions` (line 191) — the *preview* builder eight lines below keeps `groupFunctions` untouched:

```swift
        var export = SourceBuilder()
        export.add("#include <metal_stdlib>" + (kind == .layerEffect ? "\n#include <SwiftUI/SwiftUI_Metal.h>" : "") + "\nusing namespace metal;\n")
        for f in stdlib { export.add(f.source + "\n") }
        for fn in exportFunctions { export.add(fn.source, map: fn.lineMap) }
        function(into: &export, forExport: true)
```

- [ ] **Step 7: `Validation` — `reachableDefinitions` and the deleted refusal**

`Validation.swift` — compute the reachable set once per document validation (line 24):

```swift
        return out + textureTargetDiagnostics(doc, target: target, reachable: reachableDefinitions(doc))
```

Replace the head of `textureTargetDiagnostics` (lines 29-47) — the whole `.layerEffect` branch and the local `reachable` binding go:

```swift
    /// What the SwiftUI targets make of Texture Sample (spec §21.2). Document-wide, because that is
    /// the scale each rule works at.
    private static func textureTargetDiagnostics(_ doc: ShaderDocument, target: OutputTarget,
                                                 reachable: [GroupDefinition]) -> [Diagnostic] {
        guard case .stitchable(let kind) = target else { return [] }
        // The Layer Effect samples the layer instead of an asset — in the root and, since M6, in
        // every definition it emits, through the `_layer` variants (spec §22.7). Nothing to refuse.
        guard kind != .layerEffect else { return [] }

        // A Color or Distortion Effect gets no texture argument from SwiftUI and has no layer
```

The rest of the function (the anchor comment, `let anchor = samples(in: doc.root).first ?? reachable.lazy.flatMap { samples(in: $0.graph) }.first`, and the single `Diagnostic`) is unchanged and now reads the injected `reachable`.

Add the accessor just above `samples(in:)` (line 64):

```swift
    /// The definitions the root's program actually emits — every definition instantiated in the
    /// root, transitively — sorted by id so callers see a stable order (spec §22.6). Both texture
    /// target rules and the codegen agree on this set.
    public static func reachableDefinitions(_ doc: ShaderDocument) -> [GroupDefinition] {
        GroupDependencies.reachable(from: doc.root, in: doc)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
            .compactMap { doc.definitions[$0] }
    }
```

`GroupDependencies.swift` needs no change: `reachable(from:in:)` and `innerFirst(_:in:)` already provide the set and the inner-first order the variant loop walks.

- [ ] **Step 8: Run the new tests, then the whole suite and both app builds**

Run: `swift test --package-path MetalNodesKit --filter 'LayerVariantTests|TextureCodegenTests'`
Expected: green — 6 `LayerVariantTests` (`theLayerExportCompilesWithTheToolchainWhenAvailable` reports a pass rather than a skip on a machine with the Metal toolchain; it returns early and still passes without it) and the 10 remaining `TextureCodegenTests`.

Run: `swift test --package-path MetalNodesKit`
Expected: every suite green, `documentsWithoutTexturesAreUnchanged` and the `FragmentExportTests` / `ShaderExportTests` / `GroupCodegenTests` / `LineMapGroupTests` / `ViewerCodegenTests` goldens included — Core alone is 231 tests in 32 suites.

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning`
Expected: no output.

Run both `xcodebuild` commands from Global Constraints (macOS and `generic/platform=iOS Simulator`).
Expected: `BUILD SUCCEEDED` for both. No view closures changed, so the Xcode 26.6 rerun is not needed for this task.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit
git commit -m "$(cat <<'EOF'
feat(core): layer-parameter group variants — Texture Sample inside a group exports as a Layer Effect

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---
### Task 4: Platform service seams — `ImageChooser`, `Exporter`, `EditorServices`

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/PlatformServices.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Services.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/ImagePanelMac.swift` (whole file)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/ExportPanelMac.swift:11-19, 21-34, 36-59`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift:6-40, 139`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift:5-13, 111-116, 149-164, 210-217, 259-261, 272-281`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ParamControl.swift:14-16, 37-52`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorServicesTests.swift` (create)

**Interfaces:**
- Consumes: `EditorModel.importImage(data:name:) -> AssetID?`, `.replaceAssetBytes(_:data:) -> Bool`, `.exportFiles() throws(GenerationError) -> [ExportFile]`, `.beginTransaction(_:)` / `.endTransaction()`, `.apply(.setParam(_:_:_:))`, `.requestExport()` / `exportRequest`; `ExportFile`, `StitchableCodegen.sanitizedName(_:)`.
- Produces, in `PlatformServices.swift`:

```swift
public struct PickedImage: Sendable, Equatable {
    public let data: Data
    public let name: String
    public init(data: Data, name: String)
}
public enum ImageSource: Sendable, CaseIterable { case files, photos }
@MainActor public protocol ImageChooser: AnyObject {
    func choose(from source: ImageSource) async -> PickedImage?
}
public enum ExportOutcome: Sendable, Equatable { case saved, cancelled, failed(String) }
@MainActor public protocol Exporter: AnyObject {
    func export(files: [ExportFile], name: String) async -> ExportOutcome
}
@MainActor public final class MemoryImageChooser: ImageChooser {
    public var next: PickedImage?
    public private(set) var requests: [ImageSource]
    public init(next: PickedImage? = nil)
}
@MainActor public final class MemoryExporter: Exporter {
    public var outcome: ExportOutcome
    public private(set) var exported: [(files: [ExportFile], name: String)]
    public init()
}
@MainActor public struct EditorServices {
    public var imageChooser: any ImageChooser
    public var exporter: any Exporter
    public init(imageChooser: any ImageChooser, exporter: any Exporter)
    public static var platform: EditorServices { get }
}
```

- Produces, in `EditorModel+Services.swift`:

```swift
extension EditorModel {
    public func chooseImage(for node: NodeID, param: ParamID, from source: ImageSource,
                            using chooser: any ImageChooser) async
    public func relinkAsset(_ id: AssetID, from source: ImageSource,
                            using chooser: any ImageChooser) async
    public func exportShader(using exporter: any Exporter) async -> ExportOutcome
}
```

- Produces: `ImagePanelMac` and `ExportPanelMac` become `public final class`es conforming to `ImageChooser` / `Exporter`; `EditorView.init(model:device:services: EditorServices = .platform)`; `InspectorView.init(model:services: EditorServices = .platform)`; `ParamControl.onChooseImage: ((ImageSource) -> Void)?`.

- [ ] **Step 1: Write the failing tests**

`MetalNodesKit/Tests/MetalNodesUITests/EditorServicesTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

/// The platform seams (spec §22.4) driven by the in-memory doubles: what the image well's
/// "Choose…", the Assets list's "Relink…" and File ▸ Export Shader… do, with no panel and no
/// picker on screen.
@MainActor
@Suite struct EditorServicesTests {
    /// The same 2×2 PNG `EditorAssetsTests` uses — a byte literal, so no test needs the file system.
    static let png2x2 = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42mP4z/D/PwMDAwiDWP//AwBDzgf5hVEFWgAAAABJRU5ErkJggg==
        """)!
    /// A 4×1 PNG, so a relink can be told apart from the 2×2 bytes by its pixel size alone.
    static let png4x1 = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAYAAAD5PA/NAAAAEklEQVR42mP4z8DwHwwZ/oMBAEXLCff38S+qAAAAAElFTkSuQmCC
        """)!

    private func model(_ document: ShaderDocument = .starter()) -> EditorModel {
        let m = EditorModel(document: document, compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }

    private func asset(_ m: EditorModel, of node: NodeID) -> AssetID? {
        guard let v = m.document.root.nodes[node]?.params["asset"], case .asset(let a) = v else { return nil }
        return a
    }

    // MARK: Choose Image

    @Test func chooseImageImportsAndAssignsAsOneUndoStep() async throws {
        let m = model()
        let node = try #require(m.addNode(defID: "texture.sample", at: CGPoint(x: 40, y: 60)))
        let chooser = MemoryImageChooser(next: PickedImage(data: Self.png2x2, name: "Leaf.png"))
        await m.chooseImage(for: node, param: "asset", from: .photos, using: chooser)

        #expect(chooser.requests == [.photos])
        let id = try #require(asset(m, of: node))
        #expect(m.document.settings.assets[id]?.name == "Leaf.png")
        #expect(m.textures[id] == Self.png2x2)
        #expect(m.undoManager.undoActionName == "Choose Image")
        // One step: undoing it takes the manifest entry *and* the assignment back together.
        m.undo()
        #expect(asset(m, of: node) == nil)
        #expect(m.document.settings.assets.isEmpty)
        await m.awaitIdle()
    }

    @Test func aCancelledChooserChangesNothing() async throws {
        let m = model()
        let node = try #require(m.addNode(defID: "texture.sample", at: .zero))
        let before = m.document
        let version = m.undoStackVersion
        let chooser = MemoryImageChooser()                     // `next` is nil: the user cancelled
        await m.chooseImage(for: node, param: "asset", from: .files, using: chooser)

        #expect(chooser.requests == [.files])
        #expect(m.document == before)
        #expect(m.textures.isEmpty)
        #expect(m.undoStackVersion == version)                 // no transaction was ever opened
        await m.awaitIdle()
    }

    // MARK: Relink

    @Test func relinkAssetReplacesTheBytes() async throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        m.missingTextures = [id]
        let chooser = MemoryImageChooser(next: PickedImage(data: Self.png4x1, name: "Leaf.png"))
        await m.relinkAsset(id, from: .files, using: chooser)

        #expect(chooser.requests == [.files])
        #expect(m.textures[id] == Self.png4x1)
        #expect(m.document.settings.assets[id]?.pixelSize == CGSize(width: 4, height: 1))
        #expect(m.missingTextures.isEmpty)
        await m.awaitIdle()
    }

    @Test func aCancelledRelinkLeavesTheBytesAlone() async throws {
        let m = model()
        let id = try #require(m.importImage(data: Self.png2x2, name: "Leaf.png"))
        m.missingTextures = [id]
        await m.relinkAsset(id, from: .photos, using: MemoryImageChooser())

        #expect(m.textures[id] == Self.png2x2)
        #expect(m.missingTextures == [id])
        await m.awaitIdle()
    }

    // MARK: Export

    @Test func exportShaderPassesTheFilesAndReturnsTheOutcome() async throws {
        let m = model()
        let exporter = MemoryExporter()
        exporter.outcome = .saved
        #expect(await m.exportShader(using: exporter) == .saved)

        let expected = try m.exportFiles()
        #expect(exporter.exported.count == 1)
        let call = try #require(exporter.exported.first)
        #expect(call.name == "metalNodesShader")
        #expect(call.files == expected)
        #expect(call.files.map(\.name) == ["metalNodesShader.metal"])
        await m.awaitIdle()
    }

    @Test func exportShaderForwardsACancellation() async {
        let m = model()
        let exporter = MemoryExporter()
        exporter.outcome = .cancelled
        #expect(await m.exportShader(using: exporter) == .cancelled)
        await m.awaitIdle()
    }

    @Test func anInvalidGraphFailsBeforeTheExporterIsAsked() async throws {
        let m = model()
        let out = try #require(m.document.root.nodes.values.first { $0.kind == .builtin("output.fragment") })
        m.apply(.removeNodes([out.id]))
        let exporter = MemoryExporter()

        #expect(await m.exportShader(using: exporter) == .failed("The graph has errors; fix them before exporting."))
        #expect(exporter.exported.isEmpty)
        await m.awaitIdle()
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter EditorServicesTests`
Expected: FAIL to compile — `PickedImage`, `MemoryImageChooser`, `MemoryExporter`, `chooseImage(for:param:from:using:)`, `relinkAsset(_:from:using:)` and `exportShader(using:)` do not exist.

- [ ] **Step 3: The seams, the model functions and the Mac panels**

`MetalNodesKit/Sources/MetalNodesUI/Editor/PlatformServices.swift` (new):

```swift
import Foundation
import MetalNodesCore

/// The bytes of a chosen image and the file name they came in under (spec §22.4). The bytes travel,
/// not the URL: a panel's or a picker's grant covers the URL only while the caller holds it, and
/// the import copies the bytes into the package anyway.
public struct PickedImage: Sendable, Equatable {
    public let data: Data
    public let name: String
    public init(data: Data, name: String) {
        self.data = data
        self.name = name
    }
}

/// Where the user is asked for an image. The Mac has one open panel and ignores this; the iPad
/// offers Photos and Files as two separate buttons (spec §22.4).
public enum ImageSource: Sendable, CaseIterable {
    case files, photos
}

/// The image well's "Choose…" and the Assets list's "Relink…", behind a protocol so both are
/// testable in memory — the `Pasteboarding` pattern (spec §18.4) applied to the picker.
@MainActor
public protocol ImageChooser: AnyObject {
    /// The chosen bytes, or nil when the user cancelled, the file was unreadable, or a chooser is
    /// already on screen (a second request never stacks a second panel).
    func choose(from source: ImageSource) async -> PickedImage?
}

/// What File ▸ Export Shader… ended up doing. `.failed` carries the message the alert shows.
public enum ExportOutcome: Sendable, Equatable {
    case saved, cancelled, failed(String)
}

/// File ▸ Export Shader…, behind a protocol: `NSSavePanel`/`NSOpenPanel` on the Mac, `fileExporter`
/// on the iPad, an in-memory recorder in the tests (spec §22.4).
@MainActor
public protocol Exporter: AnyObject {
    /// `name` is the base name the destination should take — the folder for a stitchable target's
    /// file pair. Implementations that ask the system for a destination (both panels) may ignore it.
    func export(files: [ExportFile], name: String) async -> ExportOutcome
}

// MARK: Test doubles

/// Hands out `next` and records what it was asked for.
@MainActor
public final class MemoryImageChooser: ImageChooser {
    /// What the next `choose(from:)` returns. Nil is a cancel.
    public var next: PickedImage?
    public private(set) var requests: [ImageSource] = []

    public init(next: PickedImage? = nil) { self.next = next }

    public func choose(from source: ImageSource) async -> PickedImage? {
        requests.append(source)
        return next
    }
}

/// Records every export and answers `outcome`.
@MainActor
public final class MemoryExporter: Exporter {
    public var outcome: ExportOutcome = .saved
    public private(set) var exported: [(files: [ExportFile], name: String)] = []

    public init() {}

    public func export(files: [ExportFile], name: String) async -> ExportOutcome {
        exported.append((files, name))
        return outcome
    }
}

// MARK: Injection

/// The services one editor window runs with, injected through `EditorView`'s initializer so a test
/// (or a preview) can hand it doubles instead of panels.
@MainActor
public struct EditorServices {
    public var imageChooser: any ImageChooser
    public var exporter: any Exporter

    public init(imageChooser: any ImageChooser, exporter: any Exporter) {
        self.imageChooser = imageChooser
        self.exporter = exporter
    }

    /// What the app runs with on this platform.
    public static var platform: EditorServices {
        #if os(macOS)
        EditorServices(imageChooser: ImagePanelMac(), exporter: ExportPanelMac())
        #else
        EditorServices(imageChooser: UnavailableImageChooser(), exporter: UnavailableExporter())
        #endif
    }
}

#if os(iOS)
/// Placeholders until Task 5 lands the Pad presenters: the image well's buttons and Export exist on
/// iPad from this task on, and do nothing until the pickers are attached.
public final class UnavailableImageChooser: ImageChooser {
    public init() {}
    public func choose(from source: ImageSource) async -> PickedImage? { nil }
}

public final class UnavailableExporter: Exporter {
    public init() {}
    public func export(files: [ExportFile], name: String) async -> ExportOutcome { .cancelled }
}
#endif
```

`MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Services.swift` (new):

```swift
import Foundation
import MetalNodesCore

/// The three actions the platform services drive (spec §22.4). They live on the model, not in the
/// views, so the undo naming, the "one step" grouping and the export error message are single-sourced
/// and unit-testable with the in-memory doubles.
extension EditorModel {
    /// The image well's "Choose…": one undo step ("Choose Image") for the import and the assignment
    /// together (spec §21.2). A cancelled chooser opens no transaction, so nothing is registered.
    public func chooseImage(for node: NodeID, param: ParamID, from source: ImageSource,
                            using chooser: any ImageChooser) async {
        guard let picked = await chooser.choose(from: source) else { return }
        beginTransaction("Choose Image")
        if let asset = importImage(data: picked.data, name: picked.name) {
            apply(.setParam(node, param, .asset(asset)))
        }
        endTransaction()
    }

    /// The Assets list's "Relink…": re-imports a missing texture's bytes under its own id, so every
    /// node pointing at it keeps pointing at it (spec §21.2). `replaceAssetBytes` names its own
    /// undo step ("Replace Image") and refuses data that is not an image, with a notice.
    public func relinkAsset(_ id: AssetID, from source: ImageSource,
                            using chooser: any ImageChooser) async {
        guard let picked = await chooser.choose(from: source) else { return }
        replaceAssetBytes(id, data: picked.data)
    }

    /// File ▸ Export Shader… (spec §21.3, §22.4). A graph that does not generate is refused here,
    /// before any panel or picker is put on screen — the exporter is never asked.
    public func exportShader(using exporter: any Exporter) async -> ExportOutcome {
        let files: [ExportFile]
        do {
            files = try exportFiles()
        } catch {
            return .failed("The graph has errors; fix them before exporting.")
        }
        return await exporter.export(files: files,
                                     name: StitchableCodegen.sanitizedName(document.settings.exportName))
    }
}
```

`MetalNodesKit/Sources/MetalNodesUI/Editor/ImagePanelMac.swift` — the whole file becomes:

```swift
#if os(macOS)
import AppKit
import Foundation
import UniformTypeIdentifiers

/// The image well's "Choose…" (spec §21.2, §22.4). Reads the bytes here rather than handing the URL
/// back: the panel's grant covers the URL only for as long as the caller holds it, and the import
/// copies the bytes into the package anyway.
public final class ImagePanelMac: ImageChooser {
    public init() {}

    /// The Mac has one open panel for both sources — `source` is the iPad's Photos/Files split and
    /// has no meaning here (spec §22.4).
    public func choose(from source: ImageSource) async -> PickedImage? { Self.runPanel() }

    /// Temporary bridge for `InspectorView`'s two call sites; Step 4 moves them onto the protocol
    /// and deletes this.
    static func chooseImage() -> PickedImage? { runPanel() }

    /// The chosen file's bytes and its file name, or nil when the user cancelled or it was unreadable.
    private static func runPanel() -> PickedImage? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Choose Image"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return nil }
        return PickedImage(data: data, name: url.lastPathComponent)
    }
}
#endif
```

`MetalNodesKit/Sources/MetalNodesUI/Editor/ExportPanelMac.swift` — same panels, same messages, but every path now says which of the three outcomes it was, so a cancel is no longer indistinguishable from a success:

```swift
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MetalNodesCore

/// File ▸ Export Shader…. A single `.metal` file uses a save panel. A stitchable target's `.metal` +
/// `.swift` pair needs a folder picker instead: under App Sandbox with the user-selected-files
/// entitlement, a save panel's write grant covers only the exact URL the user picked — writing a
/// second file beside it fails with "You don't have permission…" (confirmed by hand). Picking a
/// folder via an open panel grants access to the whole directory, so both files can be written there.
public final class ExportPanelMac: Exporter {
    public init() {}

    /// `name` is the iPad's folder name; the panels ask the user for the destination themselves.
    public func export(files: [ExportFile], name: String) async -> ExportOutcome { runPanels(files: files) }

    /// Temporary bridge for `EditorView`'s macOS export branch; Step 4 deletes it. Nil on
    /// success *or* cancel, which is exactly the distinction this task exists to remove.
    static func run(files: [ExportFile]) -> String? {
        if case .failed(let message) = ExportPanelMac().runPanels(files: files) { return message }
        return nil
    }

    func runPanels(files: [ExportFile]) -> ExportOutcome {
        guard let metal = files.first(where: { $0.name.hasSuffix(".metal") }) else { return .failed("Nothing to export.") }
        guard let swift = files.first(where: { $0.name.hasSuffix(".swift") }) else {
            return runSingleFile(metal)
        }
        return runFolder(metal: metal, swift: swift)
    }

    private func runSingleFile(_ metal: ExportFile) -> ExportOutcome {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = metal.name
        panel.allowedContentTypes = [UTType(filenameExtension: "metal") ?? .sourceCode]
        panel.canCreateDirectories = true
        panel.title = "Export Shader"
        guard panel.runModal() == .OK, let url = panel.url else { return .cancelled }
        do {
            try metal.contents.write(to: url, atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func runFolder(metal: ExportFile, swift: ExportFile) -> ExportOutcome {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = "Export Shader"
        panel.prompt = "Export"
        panel.message = "Choose a folder for \(metal.name) and \(swift.name)."
        guard panel.runModal() == .OK, let dir = panel.url else { return .cancelled }
        // An open panel grants the folder, so nothing warns about replacing what is already there
        // the way a save panel would — ask before clobbering.
        let existing = [metal.name, swift.name].filter {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
        if !existing.isEmpty, !confirmReplace(existing) { return .cancelled }
        do {
            try metal.contents.write(to: dir.appendingPathComponent(metal.name), atomically: true, encoding: .utf8)
            try swift.contents.write(to: dir.appendingPathComponent(swift.name), atomically: true, encoding: .utf8)
            return .saved
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// True when the user chose Replace.
    private func confirmReplace(_ names: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Replace existing files?"
        alert.informativeText = names.count == 1
            ? "“\(names[0])” already exists in this folder. Replacing it overwrites its current contents."
            : "\(names.joined(separator: " and ")) already exist in this folder. Replacing them overwrites their current contents."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
#endif
```

Run: `swift test --package-path MetalNodesKit --filter EditorServicesTests` → all green.
Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED` (Xcode 26.6; this task stores closures in views — the PR #7 IRGen crash).

- [ ] **Step 4: The views take the services and drop their `#if os(macOS)`**

`Canvas/ParamControl.swift` — the closure now says *which* source was asked for, so one well can offer two buttons (lines 14-16 and the `imageWell` body):

```swift
    /// The image well's thumbnail: already decoded and cached by the model, because this body runs
    /// on every keystroke and every preview tick.
    var image: CGImage? = nil
    /// What the well's chooser buttons run, with the source the button stands for. Nil where there
    /// is no chooser at all (the node body's compact well), which hides them.
    var onChooseImage: ((ImageSource) -> Void)? = nil
```

```swift
    /// The image well (spec §21.2): the imported image's thumbnail, a chooser to import another,
    /// "Clear" to unassign — an unassigned Texture Sample still renders, on the placeholder. The Mac
    /// has one open panel ("Choose…"); the iPad splits it into Photos and Files (spec §22.4).
    private var imageWell: some View {
        let assigned: Bool = { if case .asset(let a) = value { return a != nil } else { return false } }()
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption)
            HStack(spacing: 8) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    if let choose = onChooseImage {
                        #if os(macOS)
                        Button("Choose…") { choose(.files) }
                        #else
                        Button("Photos…") { choose(.photos) }
                        Button("Files…") { choose(.files) }
                        #endif
                    }
                    Button("Clear") { onChange(.asset(nil)) }.disabled(!assigned)
                }
                .controlSize(.small)
            }
        }
    }
```

`Editor/InspectorView.swift` — the stored services and the initializer (lines 5-13):

```swift
public struct InspectorView: View {
    let model: EditorModel
    let services: EditorServices
    @State private var titleDraft = ""
    @State private var widthDraft = ""
    @State private var heightDraft = ""
    @State private var exportNameDraft = ""
    @FocusState private var exportNameFocused: Bool

    public init(model: EditorModel, services: EditorServices = .platform) {
        self.model = model
        self.services = services
    }
```

The param row (lines 109-116) is unchanged except that `chooseImageAction` no longer returns an optional:

```swift
        ForEach(shape.params, id: \.name) { p in
            let value = node.params[p.name] ?? p.defaultValue
            ParamControl(label: p.label, kind: p.kind, value: value,
                         onChange: { model.apply(.setParam(id, p.name, $0)) },
                         onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() },
                         image: model.assetThumbnail(for: value),
                         onChooseImage: { source in chooseImage(id, p.name, source) })
        }
```

Replace `chooseImageAction(for:param:)` (lines 149-164) with:

```swift
    /// The image well's chooser: the model owns the "Choose Image" transaction (spec §21.2, §22.4),
    /// so both platforms and both sources go through one function.
    private func chooseImage(_ node: NodeID, _ param: ParamID, _ source: ImageSource) {
        Task { await model.chooseImage(for: node, param: param, from: source, using: services.imageChooser) }
    }
```

Replace `relinkAction(for:)` (lines 272-281) with:

```swift
    /// Re-imports a missing texture's bytes under its own id, so the warning clears and every node
    /// pointing at it keeps pointing at it.
    private func relink(_ asset: AssetID, _ source: ImageSource) {
        Task { await model.relinkAsset(asset, from: source, using: services.imageChooser) }
    }
```

The Assets row's Relink button (lines 259-261) becomes, with the same Mac/iPad split as the well:

```swift
                    if missing {
                        #if os(macOS)
                        Button("Relink…") { relink(entry.id, .files) }
                        #else
                        Menu("Relink…") {
                            Button("Photos…") { relink(entry.id, .photos) }
                            Button("Files…") { relink(entry.id, .files) }
                        }
                        .fixedSize()
                        #endif
                    }
```

The Export button (lines 210-217) loses its platform gate — the iPad has an exporter from Task 5 on, and until then `UnavailableExporter` cancels:

```swift
            HStack {
                // Both actions read `settings.exportName`, so an uncommitted edit must land first.
                Button("Copy Swift snippet") { commitExportName(); _ = model.copySwiftSnippet() }
                    .disabled(s.target.stitchableKind == nil)
                Button("Export…") { commitExportName(); model.requestExport() }
            }
            .controlSize(.small)
```

`Editor/EditorView.swift` — the stored services, the initializer and the export handler (lines 6-40):

```swift
public struct EditorView: View {
    let model: EditorModel
    let device: MTLDevice
    let services: EditorServices
    @State private var exportError: String?
    /// A chooser is on screen; a second request must not stack another one behind it.
    @State private var exporting = false

    public init(model: EditorModel, device: MTLDevice, services: EditorServices = .platform) {
        self.model = model
        self.device = device
        self.services = services
    }

    public var body: some View {
        split
            .background(DraculaToken.background.color)
            .preferredColorScheme(.dark)
            .tint(DraculaToken.purple.color)
            .focusedSceneValue(\.editorModel, model)
            .onChange(of: model.exportRequest) { _, _ in
                // A modal panel must not run inside SwiftUI's update transaction (it returns
                // immediately without showing); hop to the next main-actor turn first. The iPad's
                // `fileExporter` needs the same hop for its `isPresented` write.
                Task { @MainActor in
                    guard !exporting else { return }
                    exporting = true
                    defer { exporting = false }
                    if case .failed(let message) = await model.exportShader(using: services.exporter) {
                        exportError = message
                    }
                }
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
    }
```

and line 139 passes the services on:

```swift
            InspectorView(model: model, services: services)
```

Finally delete the two bridges Step 3 left: `ImagePanelMac.chooseImage()` and `ExportPanelMac.run(files:)` (their only callers have just moved).

Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.
Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "$(cat <<'EOF'
refactor(ui): ImageChooser and Exporter seams with Mac panels and memory doubles

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---

### Task 5: Pad presenters — Photos/Files chooser and the Files exporter

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/PickerPresenter.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/ExportDocuments.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/ImageChooserPad.swift` (`#if os(iOS)`)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/ExporterPad.swift` (`#if os(iOS)`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/PlatformServices.swift` (`platform`'s iOS branch; delete `UnavailableImageChooser` / `UnavailableExporter`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift` (`body`'s tail, plus the `padHosts` extension)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/PickerPresenterTests.swift` (create), `MetalNodesKit/Tests/MetalNodesUITests/ExportDocumentsTests.swift` (create)

**Interfaces:**
- Consumes: `ImageChooser`, `Exporter`, `PickedImage`, `ImageSource`, `ExportOutcome`, `EditorServices` (T4); `ExportFile`.
- Produces, platform-neutral (compiled and tested on both platforms):

```swift
@MainActor @Observable public final class PickerPresenter<Value: Sendable> {
    public var isPresented: Bool
    public var isPending: Bool { get }
    public init()
    public func request() async -> Value?      // nil immediately when one is already pending
    public func resolve(_ value: Value?)       // ends presentation and resumes the request
}
nonisolated public struct ExportFolderDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.folder] }
    public let name: String
    public let files: [ExportFile]
    public init(name: String, files: [ExportFile])
    public init(configuration: ReadConfiguration) throws
    public func makeWrapper() -> FileWrapper
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
}
nonisolated public struct ExportTextDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.sourceCode] }
    public let name: String
    public let contents: String
    public init(file: ExportFile)
    public init(configuration: ReadConfiguration) throws
    public func makeWrapper() -> FileWrapper
    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper
}
```

- Produces, `#if os(iOS)`:

```swift
@Observable public final class ImageChooserPad: ImageChooser {
    public let photos: PickerPresenter<PickedImage>
    public let files: PickerPresenter<PickedImage>
    public init()
    public func choose(from source: ImageSource) async -> PickedImage?
}
public struct ImageChooserPadHost: ViewModifier {
    public init(chooser: ImageChooserPad?)
}
public enum ExportPadDocument: Sendable { case folder(ExportFolderDocument), text(ExportTextDocument) }
@Observable public final class ExporterPad: Exporter {
    public let presenter: PickerPresenter<ExportOutcome>
    public private(set) var pending: (document: ExportPadDocument, name: String)?
    public init()
    public func export(files: [ExportFile], name: String) async -> ExportOutcome
    public func temporaryShareURLs(files: [ExportFile], name: String) throws -> [URL]
}
public struct ExporterPadHost: ViewModifier {
    public init(exporter: ExporterPad?)
}
```

- [ ] **Step 1: Write the failing tests**

`MetalNodesKit/Tests/MetalNodesUITests/PickerPresenterTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesUI

/// The continuation behind the iPad's pickers (spec §22.4). Platform-neutral, so it is tested on
/// whichever platform the suite runs on — no picker, no window.
@MainActor
@Suite struct PickerPresenterTests {
    /// Lets a task that only awaits the presenter reach its continuation. Bounded, so a broken
    /// implementation fails the test instead of hanging the suite.
    private func waitUntilPending<Value: Sendable>(_ p: PickerPresenter<Value>) async {
        var spins = 0
        while !p.isPending, spins < 1000 {
            await Task.yield()
            spins += 1
        }
        #expect(p.isPending)
    }

    @Test func requestResolvesWithTheValue() async {
        let p = PickerPresenter<Int>()
        #expect(!p.isPresented)
        let request = Task { await p.request() }
        await waitUntilPending(p)
        #expect(p.isPresented)                     // the modifier's `isPresented` binding is true
        p.resolve(7)
        #expect(await request.value == 7)
        #expect(!p.isPresented)                    // …and false again once the value is in
        #expect(!p.isPending)
    }

    @Test func resolvingNilResumesWithNil() async {
        let p = PickerPresenter<Int>()
        let request = Task { await p.request() }
        await waitUntilPending(p)
        p.resolve(nil)                             // dismissed without picking anything
        #expect(await request.value == nil)
        #expect(!p.isPresented)
    }

    @Test func aSecondRequestWhilePendingIsRefusedAndLeavesTheFirstWaiting() async {
        let p = PickerPresenter<Int>()
        let first = Task { await p.request() }
        await waitUntilPending(p)

        #expect(await p.request() == nil)          // refused, without suspending
        #expect(p.isPending)                       // the first request is untouched…
        #expect(p.isPresented)

        p.resolve(3)
        #expect(await first.value == 3)            // …and still the one that gets the value
    }

    @Test func resolvingWithNothingPendingIsANoOp() {
        let p = PickerPresenter<Int>()
        p.resolve(1)
        #expect(!p.isPending)
        #expect(!p.isPresented)
    }
}
```

`MetalNodesKit/Tests/MetalNodesUITests/ExportDocumentsTests.swift`:

```swift
import Testing
import Foundation
import UniformTypeIdentifiers
import MetalNodesCore
@testable import MetalNodesUI

/// What `fileExporter` writes on the iPad (spec §22.4). `FileDocumentWriteConfiguration` has no
/// public initializer, so the tests go through `makeWrapper()` — the function the `FileDocument`
/// requirement forwards to.
@MainActor
@Suite struct ExportDocumentsTests {
    @Test func theFolderWrapperHoldsOneRegularFilePerExportFile() throws {
        let files = [ExportFile(name: "metalNodesShader.metal", contents: "// metal\n"),
                     ExportFile(name: "metalNodesShader.swift", contents: "// swift\n")]
        let wrapper = ExportFolderDocument(name: "metalNodesShader", files: files).makeWrapper()

        #expect(ExportFolderDocument.readableContentTypes == [.folder])
        #expect(wrapper.isDirectory)
        #expect(wrapper.preferredFilename == "metalNodesShader")
        let children = try #require(wrapper.fileWrappers)
        #expect(Set(children.keys) == Set(["metalNodesShader.metal", "metalNodesShader.swift"]))
        for file in files {
            let child = try #require(children[file.name])
            #expect(child.isRegularFile)
            #expect(child.preferredFilename == file.name)
            #expect(child.regularFileContents == Data(file.contents.utf8))
        }
    }

    @Test func theTextDocumentRoundTripsItsContents() throws {
        let file = ExportFile(name: "metalNodesShader.metal", contents: "#include <metal_stdlib>\nusing namespace metal;\n")
        let document = ExportTextDocument(file: file)
        #expect(ExportTextDocument.readableContentTypes == [.sourceCode])
        #expect(document.name == "metalNodesShader.metal")

        let wrapper = document.makeWrapper()
        #expect(wrapper.isRegularFile)
        #expect(wrapper.preferredFilename == "metalNodesShader.metal")
        let data = try #require(wrapper.regularFileContents)
        #expect(String(decoding: data, as: UTF8.self) == file.contents)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter "PickerPresenterTests|ExportDocumentsTests"`
Expected: FAIL to compile — `PickerPresenter`, `ExportFolderDocument` and `ExportTextDocument` do not exist.

- [ ] **Step 3: The presenter and the two export documents**

`MetalNodesKit/Sources/MetalNodesUI/Editor/PickerPresenter.swift` (new):

```swift
import Foundation
import Observation

/// The bridge between an `async` service call and a SwiftUI presentation modifier (spec §22.4).
/// A picker is not a function: the caller wants `await chooser.choose(…)`, SwiftUI wants an
/// `isPresented` binding and a callback. The presenter owns both ends — `request()` raises the
/// binding and suspends, the modifier's callback calls `resolve(_:)`, which lowers the binding and
/// resumes. A second request while one is on screen is refused (nil) rather than queued, the way the
/// macOS export guard already refuses to stack panels.
@MainActor
@Observable
public final class PickerPresenter<Value: Sendable> {
    /// Bound to the modifier's `isPresented:`. Written here on request and on resolve; SwiftUI may
    /// also write it to false when the sheet is dismissed, which is why the hosts resolve nil
    /// on that transition rather than relying on a callback that may never come.
    public var isPresented = false

    /// The suspended `request()`. Deliberately unobserved: the views key off `isPresented`, and a
    /// continuation is not a value SwiftUI can diff.
    @ObservationIgnored private var continuation: CheckedContinuation<Value?, Never>?

    /// Whether a `request()` is waiting for a value.
    public var isPending: Bool { continuation != nil }

    public init() {}

    /// Presents and waits. Returns nil immediately — without presenting anything — when a request is
    /// already pending.
    public func request() async -> Value? {
        guard continuation == nil else { return nil }
        isPresented = true
        return await withCheckedContinuation { c in
            // `withCheckedContinuation` runs this body synchronously, before the suspension, so a
            // `resolve` from a callback in a later turn always finds the continuation here.
            self.continuation = c
        }
    }

    /// Ends the presentation and hands `value` to the waiting `request()`. A no-op when nothing is
    /// pending, so a modifier that reports both a completion *and* a dismissal resolves once.
    public func resolve(_ value: Value?) {
        isPresented = false
        guard let c = continuation else { return }
        continuation = nil
        c.resume(returning: value)
    }
}
```

`MetalNodesKit/Sources/MetalNodesUI/Editor/ExportDocuments.swift` (new):

```swift
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import MetalNodesCore

/// The stitchable target's `.metal` + `.swift` pair, as one directory `FileWrapper` (spec §22.4).
/// `fileExporter` writes a folder in one grant, which is the same reason the Mac panel asks for a
/// folder rather than a file (see `ExportPanelMac`).
///
/// `nonisolated` because SwiftUI calls `FileDocument` off the main actor, and this module's default
/// isolation is `MainActor`.
nonisolated public struct ExportFolderDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.folder] }

    /// The folder's own name — the sanitized export name.
    public let name: String
    public let files: [ExportFile]

    public init(name: String, files: [ExportFile]) {
        self.name = name
        self.files = files
    }

    /// Export-only: nothing in the app opens one of these back.
    public init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadUnsupportedScheme)
    }

    /// The wrapper the exporter writes. Split out of the `FileDocument` requirement because
    /// `FileDocumentWriteConfiguration` has no public initializer, so the tests cannot call it.
    public func makeWrapper() -> FileWrapper {
        var children: [String: FileWrapper] = [:]
        for file in files {
            let child = FileWrapper(regularFileWithContents: Data(file.contents.utf8))
            child.preferredFilename = file.name
            children[file.name] = child
        }
        let directory = FileWrapper(directoryWithFileWrappers: children)
        directory.preferredFilename = name
        return directory
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { makeWrapper() }
}

/// The fragment target's single `.metal` file, exported directly rather than inside a folder.
nonisolated public struct ExportTextDocument: FileDocument {
    public static var readableContentTypes: [UTType] { [.sourceCode] }

    public let name: String
    public let contents: String

    public init(file: ExportFile) {
        self.name = file.name
        self.contents = file.contents
    }

    public init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.name = configuration.file.preferredFilename ?? "Shader.metal"
        self.contents = String(decoding: data, as: UTF8.self)
    }

    public func makeWrapper() -> FileWrapper {
        let wrapper = FileWrapper(regularFileWithContents: Data(contents.utf8))
        wrapper.preferredFilename = name
        return wrapper
    }

    public func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { makeWrapper() }
}
```

Run: `swift test --package-path MetalNodesKit --filter "PickerPresenterTests|ExportDocumentsTests"` → all green.
Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.

- [ ] **Step 4: The Photos/Files image chooser**

`MetalNodesKit/Sources/MetalNodesUI/Editor/ImageChooserPad.swift` (new):

```swift
#if os(iOS)
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Foundation
import Observation

/// The iPad's image well chooser (spec §22.4): "Photos…" opens a `PhotosPicker`, "Files…" a
/// document picker. Both are SwiftUI presentation modifiers, so the chooser holds one
/// `PickerPresenter` each and `EditorView` attaches `ImageChooserPadHost` once for the whole window.
///
/// `PhotosPicker` needs no usage description and no authorization: the picker runs out of process
/// and hands back only what the user chose.
@Observable
public final class ImageChooserPad: ImageChooser {
    public let photos = PickerPresenter<PickedImage>()
    public let files = PickerPresenter<PickedImage>()

    public init() {}

    public func choose(from source: ImageSource) async -> PickedImage? {
        switch source {
        case .photos: await photos.request()
        case .files: await files.request()
        }
    }
}

/// Attaches both pickers. Takes an optional so `EditorView` can hand it
/// `services.imageChooser as? ImageChooserPad` — nil for the in-memory double, and then this is a
/// pass-through.
public struct ImageChooserPadHost: ViewModifier {
    let chooser: ImageChooserPad?
    @State private var photoItem: PhotosPickerItem?
    /// A photo's bytes arrive asynchronously, *after* the picker has already dismissed itself. The
    /// dismissal must not be read as a cancel while this is true.
    @State private var loadingPhoto = false

    public init(chooser: ImageChooserPad?) { self.chooser = chooser }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let chooser {
            attach(content, chooser)
        } else {
            content
        }
    }

    private func attach(_ content: Content, _ chooser: ImageChooserPad) -> some View {
        @Bindable var photos = chooser.photos
        @Bindable var files = chooser.files
        return content
            .photosPicker(isPresented: $photos.isPresented, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                loadingPhoto = true
                Task { @MainActor in
                    let picked = await load(item)
                    photoItem = nil
                    loadingPhoto = false
                    chooser.photos.resolve(picked)
                }
            }
            .onChange(of: chooser.photos.isPresented) { _, presented in
                // `PhotosPicker` has no cancel callback: a dismissal with nothing loading is the
                // user backing out, and the awaiting `choose(from:)` has to be resumed.
                if !presented, !loadingPhoto { chooser.photos.resolve(nil) }
            }
            .fileImporter(isPresented: $files.isPresented,
                          allowedContentTypes: [.png, .jpeg, .heic],
                          allowsMultipleSelection: false) { result in
                chooser.files.resolve(picked(from: result))
            } onCancellation: {
                chooser.files.resolve(nil)
            }
    }

    /// The photo's original bytes. `Data` rather than `Image`: the import stores what the user
    /// picked verbatim, never a re-encode (spec §21.2). The name is the item's own type extension —
    /// a `PhotosPickerItem` carries no file name.
    private func load(_ item: PhotosPickerItem) async -> PickedImage? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "png"
        return PickedImage(data: data, name: "Photo." + ext)
    }

    /// The picked file's bytes, read under the document picker's security-scoped grant — the same
    /// claim a Finder drop needs (see `EditorModel.addTextureNode(contentsOf:at:)`).
    private func picked(from result: Result<[URL], any Error>) -> PickedImage? {
        guard case .success(let urls) = result, let url = urls.first else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return PickedImage(data: data, name: url.lastPathComponent)
    }
}
#endif
```

No unit test can drive `PhotosPicker` or `fileImporter` — they are system pickers in another process. `PickerPresenter` carries the logic that *is* testable (Step 1); the pickers themselves are checked by the iPad Simulator checklist in Task 11.

Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.

- [ ] **Step 5: The Files exporter, the platform defaults and the host modifiers**

`MetalNodesKit/Sources/MetalNodesUI/Editor/ExporterPad.swift` (new):

```swift
#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers
import Foundation
import Observation
import MetalNodesCore

/// Which document `fileExporter` is being handed. A stitchable target's file pair goes out as one
/// folder; the fragment target's single `.metal` goes out as itself (spec §22.4).
public enum ExportPadDocument: Sendable {
    case folder(ExportFolderDocument)
    case text(ExportTextDocument)
}

/// The iPad's File ▸ Export Shader… (spec §22.4): builds the document, raises the presenter, and
/// waits for `fileExporter`'s completion. `ExporterPadHost` is what actually presents it.
@Observable
public final class ExporterPad: Exporter {
    public let presenter = PickerPresenter<ExportOutcome>()
    /// What the host should present, and the file name it should default to. Nil between exports.
    public private(set) var pending: (document: ExportPadDocument, name: String)?

    public init() {}

    public func export(files: [ExportFile], name: String) async -> ExportOutcome {
        guard !presenter.isPending else { return .cancelled }
        guard let first = files.first else { return .failed("Nothing to export.") }
        // One file is exported as itself under its own name; a pair needs the folder, whose name is
        // the export name.
        pending = files.count == 1
            ? (.text(ExportTextDocument(file: first)), first.name)
            : (.folder(ExportFolderDocument(name: name, files: files)), name)
        let outcome = await presenter.request() ?? .cancelled
        pending = nil
        return outcome
    }

    /// The document the folder exporter presents, and nil while a text export is pending — the two
    /// `fileExporter` modifiers are told apart by these.
    public var folderDocument: ExportFolderDocument? {
        guard let pending, case .folder(let d) = pending.document else { return nil }
        return d
    }

    public var textDocument: ExportTextDocument? {
        guard let pending, case .text(let d) = pending.document else { return nil }
        return d
    }

    /// Ends the presentation with `outcome` and drops the document.
    func finish(_ outcome: ExportOutcome) {
        pending = nil
        presenter.resolve(outcome)
    }

    /// `fileExporter`'s completion, mapped onto the outcome the alert reads.
    func finish(_ result: Result<URL, any Error>) {
        switch result {
        case .success: finish(.saved)
        case .failure(let error): finish(.failed(error.localizedDescription))
        }
    }

    /// The same files on disk, for the toolbar's `ShareLink` (Task 8). A share sheet takes URLs, not
    /// documents, so the files are written under `tmp/Exports/<uuid>/<name>/` — a fresh folder per
    /// share, so two shares never race over one path, and the system reclaims `tmp`.
    public func temporaryShareURLs(files: [ExportFile], name: String) throws -> [URL] {
        let directory = URL.temporaryDirectory
            .appending(path: "Exports", directoryHint: .isDirectory)
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try files.map { file in
            let url = directory.appending(path: file.name, directoryHint: .notDirectory)
            try Data(file.contents.utf8).write(to: url, options: .atomic)
            return url
        }
    }
}

/// Attaches the two exporters. Optional for the same reason `ImageChooserPadHost` is: the tests
/// inject `MemoryExporter`, and then this is a pass-through.
public struct ExporterPadHost: ViewModifier {
    let exporter: ExporterPad?

    public init(exporter: ExporterPad?) { self.exporter = exporter }

    @ViewBuilder
    public func body(content: Content) -> some View {
        if let exporter {
            attach(content, exporter)
        } else {
            content
        }
    }

    private func attach(_ content: Content, _ exporter: ExporterPad) -> some View {
        content
            .fileExporter(isPresented: isPresented(exporter, folder: true),
                          document: exporter.folderDocument,
                          contentType: .folder,
                          defaultFilename: exporter.pending?.name,
                          onCompletion: { exporter.finish($0) },
                          onCancellation: { exporter.finish(.cancelled) })
            .fileExporter(isPresented: isPresented(exporter, folder: false),
                          document: exporter.textDocument,
                          contentType: .sourceCode,
                          defaultFilename: exporter.pending?.name,
                          onCompletion: { exporter.finish($0) },
                          onCancellation: { exporter.finish(.cancelled) })
    }

    /// One presenter drives two modifiers, so each takes the flag only while *its* document is the
    /// pending one. The setter never resolves: `onCompletion` and `onCancellation` between them
    /// cover every dismissal, and resolving here would race a save with a `.cancelled`.
    private func isPresented(_ exporter: ExporterPad, folder: Bool) -> Binding<Bool> {
        Binding(get: { exporter.presenter.isPresented && (folder ? exporter.folderDocument != nil : exporter.textDocument != nil) },
                set: { if !$0 { exporter.presenter.isPresented = false } })
    }
}
#endif
```

`Editor/PlatformServices.swift` — `platform` now hands the iPad its presenters, and the two placeholders go:

```swift
    /// What the app runs with on this platform.
    public static var platform: EditorServices {
        #if os(macOS)
        EditorServices(imageChooser: ImagePanelMac(), exporter: ExportPanelMac())
        #else
        EditorServices(imageChooser: ImageChooserPad(), exporter: ExporterPad())
        #endif
    }
```

Delete the whole `#if os(iOS) … UnavailableImageChooser … UnavailableExporter … #endif` block at the end of the file.

`Editor/EditorView.swift` — one attachment point for both hosts, at the end of `body`:

```swift
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
            .padHosts(services)
    }
```

and, at the bottom of the file:

```swift
private extension View {
    /// The iPad pickers' single attachment point (spec §22.4): the presenters are per-window state,
    /// so their modifiers go on the window's root view exactly once. A no-op on macOS, and a
    /// pass-through whenever the injected services are not the Pad ones (the tests' doubles).
    @ViewBuilder
    func padHosts(_ services: EditorServices) -> some View {
        #if os(iOS)
        modifier(ImageChooserPadHost(chooser: services.imageChooser as? ImageChooserPad))
            .modifier(ExporterPadHost(exporter: services.exporter as? ExporterPad))
        #else
        self
        #endif
    }
}
```

Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "$(cat <<'EOF'
feat(ui): Photos/Files image chooser and Files exporter on iPad

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---
### Task 6: `CanvasMode` and the pure `TouchIntentMapper`

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift:29-35` (two new fields), `:49-77` (the hand-written `Codable`), plus the new `CanvasMode` above the struct
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/CanvasTransform.swift:5` (`nonisolated`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Selection.swift:4` (`nonisolated`)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/TouchIntentMapper.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/EditorViewStateTests.swift` (create), `MetalNodesKit/Tests/MetalNodesUITests/TouchIntentMapperTests.swift` (create)

**Interfaces:**
- Consumes: `NodeID`, `CommentID`, `SocketRef`, `EditorViewState` (Core); `SelectionMode`, `CanvasTransform` (UI).
- Produces (Core): `public enum CanvasMode: String, Codable, Sendable, CaseIterable { case pointer, select, lasso }`; `EditorViewState.canvasMode: CanvasMode` (default `.pointer`), `EditorViewState.showsInspector: Bool` (default `true`), both decoding as their default when the key is absent.
- Produces (UI): `public enum CanvasHit: Equatable, Sendable`, `public enum CanvasIntent: Equatable, Sendable`, `public enum TouchEvent: Equatable, Sendable`, `public struct TouchContext`, `public struct TouchIntentMapper { static let dragThreshold: CGFloat = 6; init(); mutating func map(_ event: TouchEvent, in context: TouchContext) -> [CanvasIntent] }` — all `nonisolated`.
- Changes isolation only: `CanvasTransform` and `SelectionMode` become `nonisolated` (they are unannotated today, so `.defaultIsolation(MainActor.self)` makes them main-actor-isolated). Every existing call site is already on the main actor, so nothing else moves.

> **Ruling — where `CanvasMode` lives.** The File structure section lists `Canvas/CanvasMode.swift`; it is not created. `CanvasMode` is persisted view state, so it belongs next to `EditorViewState` in Core (spec §22.2 stores it in `EditorViewState.canvasMode`), and `MetalNodesUI` gets it through the `MetalNodesCore` import it already has.

> **Ruling — two `nonisolated` keywords.** `MetalNodesUI` builds with `.defaultIsolation(MainActor.self)`, which isolates *types*, not just functions. A `nonisolated struct TouchIntentMapper` that calls `context.transform.toCanvas(p)` fails with `error: call to main actor-isolated instance method 'toCanvas' in a synchronous nonisolated context`, and a `nonisolated` function comparing two `SelectionMode`s fails with `error: main actor-isolated conformance of 'SelectionMode' to 'Equatable' cannot be used in nonisolated context` — which would otherwise make `CanvasIntent`'s synthesized `Equatable` an isolated conformance behind the API's back. Marking both pure value types `nonisolated` is a strict widening: main-actor callers are unaffected.

- [ ] **Step 1: Write the failing Core test**

`MetalNodesKit/Tests/MetalNodesCoreTests/EditorViewStateTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// View state is persisted next to the document and read back by older and newer builds alike
/// (spec §5, §22.2): a key that is not there must decode as the default, never as a failure.
@Suite struct EditorViewStateTests {
    @Test func freshStateStartsInPointerModeWithTheInspectorShowing() {
        let s = EditorViewState()
        #expect(s.canvasMode == .pointer)
        #expect(s.showsInspector)
    }

    @Test func jsonWithoutTheM6KeysDecodesAsTheDefaults() throws {
        // An M5 view.json: none of the M6 keys exist in it.
        let json = Data("{}".utf8)
        let s = try JSONDecoder().decode(EditorViewState.self, from: json)
        #expect(s.canvasMode == .pointer)
        #expect(s.showsInspector)
        #expect(s == EditorViewState())          // and nothing else drifted
    }

    @Test func canvasModeAndInspectorRoundTrip() throws {
        var s = EditorViewState()
        s.canvasMode = .lasso
        s.showsInspector = false
        s.showsCode = true
        s.cameras[.root] = Camera(pan: CGSize(width: 3, height: 4), zoom: 2)
        let back = try JSONDecoder().decode(EditorViewState.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    /// The mode is persisted by name, so the three spellings are file format and may not be
    /// renamed without a migration.
    @Test func modesEncodeAsTheirNames() throws {
        #expect(CanvasMode.allCases.map(\.rawValue) == ["pointer", "select", "lasso"])
        var s = EditorViewState()
        s.canvasMode = .select
        let text = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(text.contains("\"canvasMode\":\"select\""))
        #expect(text.contains("\"showsInspector\":true"))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter EditorViewStateTests`
Expected: FAIL — `CanvasMode`, `canvasMode` and `showsInspector` do not exist.

- [ ] **Step 3: Add `CanvasMode` and the two fields**

`MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift` — above `EditorViewState`, after `Camera`:

```swift
/// What a one-finger drag on the canvas does (spec §22.2). Persisted view state, never
/// snapshotted or undone; on macOS it exists but nothing reads it.
public enum CanvasMode: String, Codable, Sendable, CaseIterable {
    case pointer, select, lasso
}
```

The two new fields, after `showsMinimap`:

```swift
    /// View ▸ Minimap, on by default (spec §21.6).
    public var showsMinimap = true
    /// The iPad canvas's drag mode (spec §22.2). `.pointer` for every document that predates M6.
    public var canvasMode: CanvasMode = .pointer
    /// The iPad's trailing inspector column — preview, inspector and (with `showsCode`) the code
    /// panel — on by default (spec §22.3).
    public var showsInspector = true
    public init() {}
```

The whole `Codable` extension, with the three edited members:

```swift
extension EditorViewState: Codable {
    private enum Keys: String, CodingKey {
        case cameras, editingStack, editingDefinition, viewer, viewerPath, viewerDefinition, selection
        case selectedComments, showsCode, showsMinimap, canvasMode, showsInspector
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cameras = try c.decodeIfPresent([GraphPath: Camera].self, forKey: .cameras) ?? [:]
        editingStack = try c.decodeIfPresent([NodeID].self, forKey: .editingStack) ?? []
        editingDefinition = try c.decodeIfPresent(GroupID.self, forKey: .editingDefinition)
        viewer = try c.decodeIfPresent(SocketRef.self, forKey: .viewer)
        viewerPath = try c.decodeIfPresent([NodeID].self, forKey: .viewerPath) ?? []
        viewerDefinition = try c.decodeIfPresent(GroupID.self, forKey: .viewerDefinition)
        selection = try c.decodeIfPresent(Set<NodeID>.self, forKey: .selection) ?? []
        selectedComments = try c.decodeIfPresent(Set<CommentID>.self, forKey: .selectedComments) ?? []
        showsCode = try c.decodeIfPresent(Bool.self, forKey: .showsCode) ?? false
        showsMinimap = try c.decodeIfPresent(Bool.self, forKey: .showsMinimap) ?? true
        canvasMode = try c.decodeIfPresent(CanvasMode.self, forKey: .canvasMode) ?? .pointer
        showsInspector = try c.decodeIfPresent(Bool.self, forKey: .showsInspector) ?? true
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(cameras, forKey: .cameras); try c.encode(editingStack, forKey: .editingStack)
        try c.encodeIfPresent(editingDefinition, forKey: .editingDefinition)
        try c.encodeIfPresent(viewer, forKey: .viewer); try c.encode(viewerPath, forKey: .viewerPath)
        try c.encodeIfPresent(viewerDefinition, forKey: .viewerDefinition)
        try c.encode(selection, forKey: .selection)
        try c.encode(selectedComments, forKey: .selectedComments)
        try c.encode(showsCode, forKey: .showsCode); try c.encode(showsMinimap, forKey: .showsMinimap)
        try c.encode(canvasMode, forKey: .canvasMode); try c.encode(showsInspector, forKey: .showsInspector)
    }
}
```

Run: `swift test --package-path MetalNodesKit --filter EditorViewStateTests` → green.

- [ ] **Step 4: Write the failing mapper test**

`MetalNodesKit/Tests/MetalNodesUITests/TouchIntentMapperTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

/// Every row of the §22.2 gesture table, in every mode it behaves differently in, plus the
/// thresholds and the two "difference since the last report" gestures. Events carry **viewport**
/// points; the context's transform is at zoom 2 with a non-zero pan, so every canvas/viewport
/// conversion the mapper makes is exercised rather than being the identity.
@Suite struct TouchIntentMapperTests {
    let nodeID = NodeID()
    let wireOwner = NodeID()
    let sticky = CommentID.sticky(StickyID())
    let transform = CanvasTransform(pan: CGSize(width: 20, height: 10), zoom: 2)

    // Viewport points, and the canvas points they map to: (v.x - 20) / 2, (v.y - 10) / 2.
    let onNode = CGPoint(x: 120, y: 110)        // canvas (50, 50)
    let onComment = CGPoint(x: 520, y: 510)     // canvas (250, 250)
    let onSocket = CGPoint(x: 320, y: 310)      // canvas (150, 150)
    let onWire = CGPoint(x: 420, y: 410)        // canvas (200, 200)
    let onEmpty = CGPoint(x: 220, y: 210)       // canvas (100, 100)

    private var socketRef: SocketRef { SocketRef(nodeID, "out") }
    private var wireRef: SocketRef { SocketRef(wireOwner, "a") }
    private func canvas(_ p: CGPoint) -> CGPoint { transform.toCanvas(p) }

    /// The canvas's hit test, faked: the four canvas points above are the four kinds of hit and
    /// everything else is empty canvas.
    private var everything: [CGPoint: CanvasHit] {
        [canvas(onNode): .node(nodeID),
         canvas(onComment): .comment(sticky),
         canvas(onSocket): .socket(socketRef, isInput: false),
         canvas(onWire): .wire(wireRef)]
    }

    private func context(_ mode: CanvasMode, hits: [CGPoint: CanvasHit] = [:],
                         selected: [CanvasHit] = []) -> TouchContext {
        TouchContext(mode: mode, transform: transform,
                     hitTest: { hits[$0] ?? .empty },
                     isSelected: { selected.contains($0) })
    }

    // MARK: Tap

    @Test(arguments: [CanvasMode.pointer, .lasso])
    func tapOnANodeReplacesTheSelection(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onNode), in: context(mode, hits: everything)) == [.select(.node(nodeID), .replace)])
    }

    @Test func tapOnANodeTogglesItInSelectMode() {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onNode), in: context(.select, hits: everything)) == [.select(.node(nodeID), .toggle)])
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnACommentFollowsTheSameRuleAsANode(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let expected: SelectionMode = mode == .select ? .toggle : .replace
        #expect(m.map(.tap(onComment), in: context(mode, hits: everything)) == [.select(.comment(sticky), expected)])
    }

    /// A wire selection is a single ref in the model, so it always replaces — there is no
    /// "add this wire to the selection".
    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnAWireAlwaysReplaces(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onWire), in: context(mode, hits: everything)) == [.select(.wire(wireRef), .replace)])
    }

    /// A finger is 20 pt wide: a tap that lands on a socket means the node, not the wire drag.
    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func tapOnASocketSelectsItsNode(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let expected: SelectionMode = mode == .select ? .toggle : .replace
        #expect(m.map(.tap(onSocket), in: context(mode, hits: everything)) == [.select(.node(nodeID), expected)])
    }

    @Test(arguments: [CanvasMode.pointer, .lasso])
    func tapOnEmptyCanvasClearsTheSelection(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onEmpty), in: context(mode, hits: everything)) == [.clearSelection])
    }

    @Test func tapOnEmptyCanvasKeepsTheSelectionInSelectMode() {
        var m = TouchIntentMapper()
        #expect(m.map(.tap(onEmpty), in: context(.select, hits: everything)).isEmpty)
    }

    // MARK: Double tap and long press

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func doubleTapOnEmptyCanvasOpensTheChooserAtTheViewportPoint(mode: CanvasMode) {
        var m = TouchIntentMapper()
        #expect(m.map(.doubleTap(onEmpty), in: context(mode, hits: everything)) == [.openChooser(at: onEmpty)])
    }

    @Test func doubleTapOnAnythingElseDoesNothing() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        #expect(m.map(.doubleTap(onNode), in: c).isEmpty)
        #expect(m.map(.doubleTap(onSocket), in: c).isEmpty)
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func longPressAlwaysOpensTheContextMenuWithWhatItHit(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        #expect(m.map(.longPress(onNode), in: c) == [.contextMenu(at: onNode, hit: .node(nodeID))])
        #expect(m.map(.longPress(onEmpty), in: c) == [.contextMenu(at: onEmpty, hit: .empty)])
    }

    // MARK: One-finger drag

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func dragOnAnUnselectedNodeSelectsItThenMoves(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        #expect(m.map(.dragBegan(onNode), in: c).isEmpty)
        let first = CGSize(width: 8, height: 0)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 8, y: onNode.y), translation: first), in: c)
                == [.select(.node(nodeID), .replace), .beginMove(.node(nodeID)), .move(first)])
        let second = CGSize(width: 20, height: 6)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 20, y: onNode.y + 6), translation: second), in: c)
                == [.move(second)])
        #expect(m.map(.dragEnded(location: CGPoint(x: onNode.x + 20, y: onNode.y + 6), translation: second), in: c)
                == [.move(second), .endMove])
    }

    /// An already-selected node must not be re-selected: that would collapse a multi-node
    /// selection to the one finger landed on, and the whole selection is what moves.
    @Test func dragOnASelectedNodeDoesNotTouchTheSelection() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything, selected: [.node(nodeID)])
        _ = m.map(.dragBegan(onNode), in: c)
        let t = CGSize(width: 0, height: 9)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x, y: onNode.y + 9), translation: t), in: c)
                == [.beginMove(.node(nodeID)), .move(t)])
    }

    @Test func dragOnACommentMovesTheComment() {
        var m = TouchIntentMapper()
        let c = context(.lasso, hits: everything)
        _ = m.map(.dragBegan(onComment), in: c)
        let t = CGSize(width: 12, height: 0)
        #expect(m.map(.dragChanged(location: CGPoint(x: onComment.x + 12, y: onComment.y), translation: t), in: c)
                == [.select(.comment(sticky), .replace), .beginMove(.comment(sticky)), .move(t)])
        #expect(m.map(.dragEnded(location: CGPoint(x: onComment.x + 12, y: onComment.y), translation: t), in: c)
                == [.move(t), .endMove])
    }

    @Test(arguments: [CanvasMode.pointer, .select, .lasso])
    func dragFromASocketWiresInCanvasCoordinates(mode: CanvasMode) {
        var m = TouchIntentMapper()
        let c = context(mode, hits: everything)
        _ = m.map(.dragBegan(onSocket), in: c)
        let moved = CGPoint(x: onSocket.x + 10, y: onSocket.y)
        #expect(m.map(.dragChanged(location: moved, translation: CGSize(width: 10, height: 0)), in: c)
                == [.beginWire(socketRef, isInput: false), .wire(canvas(moved))])
        let dropped = CGPoint(x: onSocket.x + 40, y: onSocket.y + 20)
        #expect(m.map(.dragEnded(location: dropped, translation: CGSize(width: 40, height: 20)), in: c)
                == [.endWire(canvas(dropped))])
    }

    /// Pointer mode pans, by the *difference* since the last change — the canvas adds each delta
    /// to the live transform rather than to a remembered origin.
    @Test func dragOnEmptyCanvasPansByTheDeltaSinceTheLastChange() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onEmpty), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onEmpty.x + 10, y: onEmpty.y),
                                   translation: CGSize(width: 10, height: 0)), in: c) == [.pan(CGSize(width: 10, height: 0))])
        #expect(m.map(.dragChanged(location: CGPoint(x: onEmpty.x + 30, y: onEmpty.y + 5),
                                   translation: CGSize(width: 30, height: 5)), in: c) == [.pan(CGSize(width: 20, height: 5))])
        #expect(m.map(.dragEnded(location: CGPoint(x: onEmpty.x + 30, y: onEmpty.y + 5),
                                 translation: CGSize(width: 30, height: 5)), in: c) == [.endPan])
    }

    /// A wire is not a drag handle: a drag that starts on one pans (or marquees) like empty canvas.
    @Test func dragStartingOnAWirePansLikeEmptyCanvas() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onWire), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onWire.x + 12, y: onWire.y),
                                   translation: CGSize(width: 12, height: 0)), in: c) == [.pan(CGSize(width: 12, height: 0))])
    }

    @Test func dragOnEmptyCanvasMarqueesAndAddsInSelectMode() {
        var m = TouchIntentMapper()
        let c = context(.select, hits: everything)
        _ = m.map(.dragBegan(onEmpty), in: c)
        let moved = CGPoint(x: onEmpty.x + 40, y: onEmpty.y + 20)          // canvas (120, 110)
        let rect = CGRect(x: 100, y: 100, width: 20, height: 10)
        #expect(m.map(.dragChanged(location: moved, translation: CGSize(width: 40, height: 20)), in: c)
                == [.beginMarquee(CGPoint(x: 100, y: 100)), .marquee(rect)])
        #expect(m.map(.dragEnded(location: moved, translation: CGSize(width: 40, height: 20)), in: c)
                == [.endMarquee(rect, .add)])
    }

    /// Lasso mode marquees the same way but replaces, and the rect normalises when the finger
    /// travels up and to the left.
    @Test func lassoMarqueeReplacesTheSelection() {
        var m = TouchIntentMapper()
        let c = context(.lasso, hits: everything)
        let start = CGPoint(x: 620, y: 610)                                // canvas (300, 300), empty
        _ = m.map(.dragBegan(start), in: c)
        let moved = CGPoint(x: start.x - 60, y: start.y - 20)              // canvas (270, 290)
        let translation = CGSize(width: -60, height: -20)
        // Up and to the left: the rect normalises around the press point.
        let rect = CGRect(x: 270, y: 290, width: 30, height: 10)
        #expect(m.map(.dragChanged(location: moved, translation: translation), in: c)
                == [.beginMarquee(CGPoint(x: 300, y: 300)), .marquee(rect)])
        #expect(m.map(.dragEnded(location: moved, translation: translation), in: c)
                == [.endMarquee(rect, .replace)])
    }

    // MARK: Thresholds

    @Test func aDragLatchesOnlyOnceItPassesSixPoints() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onNode), in: c)
        // hypot(4, 3) == 5: still a tap as far as the mapper is concerned.
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 4, y: onNode.y + 3),
                                   translation: CGSize(width: 4, height: 3)), in: c).isEmpty)
        // hypot(5, 4) ≈ 6.4: latches, from the *press* point, not from where the finger is now.
        let t = CGSize(width: 5, height: 4)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 5, y: onNode.y + 4), translation: t), in: c)
                == [.select(.node(nodeID), .replace), .beginMove(.node(nodeID)), .move(t)])
    }

    @Test func aDragThatEndsBeforeLatchingEmitsNothing() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        _ = m.map(.dragBegan(onNode), in: c)
        #expect(m.map(.dragChanged(location: CGPoint(x: onNode.x + 2, y: onNode.y + 2),
                                   translation: CGSize(width: 2, height: 2)), in: c).isEmpty)
        // The tap recognizer handles this touch; the drag must not open a transaction it never closes.
        #expect(m.map(.dragEnded(location: CGPoint(x: onNode.x + 3, y: onNode.y),
                                 translation: CGSize(width: 3, height: 0)), in: c).isEmpty)
    }

    // MARK: Two fingers

    @Test func twoFingerPanEmitsTheDeltaSinceTheLastReport() {
        var m = TouchIntentMapper()
        let c = context(.select, hits: everything)          // pans in every mode
        #expect(m.map(.twoFingerPan(CGSize(width: 10, height: 0)), in: c) == [.pan(CGSize(width: 10, height: 0))])
        #expect(m.map(.twoFingerPan(CGSize(width: 25, height: 4)), in: c) == [.pan(CGSize(width: 15, height: 4))])
        #expect(m.map(.twoFingerPanEnded, in: c) == [.endPan])
        // The next gesture starts from zero again, not from 25.
        #expect(m.map(.twoFingerPan(CGSize(width: 5, height: 0)), in: c) == [.pan(CGSize(width: 5, height: 0))])
    }

    @Test func pinchEmitsTheRatioBetweenReportsAroundTheCentroid() {
        var m = TouchIntentMapper()
        let c = context(.pointer, hits: everything)
        #expect(m.map(.pinch(scale: 2, centroid: onEmpty), in: c) == [.zoom(2, around: onEmpty)])
        #expect(m.map(.pinch(scale: 3, centroid: onEmpty), in: c) == [.zoom(1.5, around: onEmpty)])
        #expect(m.map(.pinchEnded, in: c) == [.endZoom])
        #expect(m.map(.pinch(scale: 2, centroid: onNode), in: c) == [.zoom(2, around: onNode)])
    }
}
```

- [ ] **Step 5: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter TouchIntentMapperTests`
Expected: FAIL — `TouchIntentMapper`, `TouchContext`, `TouchEvent`, `CanvasHit`, `CanvasIntent` do not exist.

- [ ] **Step 6: Widen the two value types' isolation**

`MetalNodesKit/Sources/MetalNodesUI/Canvas/CanvasTransform.swift`:

```swift
/// Pan/zoom math for the node canvas. Screen = canvas × zoom + pan.
///
/// `nonisolated` because `TouchIntentMapper` is: the module's default isolation would otherwise
/// make `toCanvas` a main-actor method the pure mapper cannot call (spec §22.2).
nonisolated public struct CanvasTransform: Equatable, Sendable {
```

`MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Selection.swift`:

```swift
/// `nonisolated` so `CanvasIntent`'s synthesized `Equatable` is a plain conformance rather than a
/// main-actor-isolated one (the module defaults to `MainActor` isolation).
nonisolated public enum SelectionMode: Sendable { case replace, add, toggle }
```

- [ ] **Step 7: Write the mapper**

`MetalNodesKit/Sources/MetalNodesUI/Canvas/TouchIntentMapper.swift` (whole file):

```swift
import CoreGraphics
import MetalNodesCore

/// What a canvas point belongs to (spec §22.2). `GraphCanvasView.hit(at:)` answers this from the
/// same anchors, frames and wire distances the mouse path uses.
nonisolated public enum CanvasHit: Equatable, Sendable {
    case node(NodeID)
    case comment(CommentID)
    case socket(SocketRef, isInput: Bool)
    case wire(SocketRef)
    case empty
}

/// What the canvas should *do*. Every case maps onto a function the mouse path already calls, so
/// selection, wiring, transactions and undo names stay single-sourced (spec §22.2).
nonisolated public enum CanvasIntent: Equatable, Sendable {
    case select(CanvasHit, SelectionMode)
    case clearSelection
    case beginMove(CanvasHit)
    /// Translation since the drag began, in viewport points — the same value `DragGesture`
    /// hands `NodeView.onDrag`, which is why the canvas can reuse `moveSelection(by:)`.
    case move(CGSize)
    case endMove
    case beginWire(SocketRef, isInput: Bool)
    /// Canvas coordinates.
    case wire(CGPoint)
    /// Canvas coordinates.
    case endWire(CGPoint)
    /// Canvas coordinates.
    case beginMarquee(CGPoint)
    case marquee(CGRect)
    case endMarquee(CGRect, SelectionMode)
    /// Pan the camera by this many viewport points — a delta, not a cumulative translation.
    case pan(CGSize)
    case endPan
    /// Multiply the zoom by this factor, keeping the viewport point under it stationary.
    case zoom(CGFloat, around: CGPoint)
    case endZoom
    /// Viewport point.
    case contextMenu(at: CGPoint, hit: CanvasHit)
    /// Viewport point.
    case openChooser(at: CGPoint)
}

/// What the overlay's recognizers report, in **viewport** coordinates (spec §22.2). One event per
/// recognizer callback; the mapper owns everything stateful about a drag.
nonisolated public enum TouchEvent: Equatable, Sendable {
    case tap(CGPoint)
    case doubleTap(CGPoint)
    case longPress(CGPoint)
    case dragBegan(CGPoint)
    case dragChanged(location: CGPoint, translation: CGSize)
    case dragEnded(location: CGPoint, translation: CGSize)
    /// The recognizer's cumulative translation; the mapper emits the difference.
    case twoFingerPan(CGSize)
    case twoFingerPanEnded
    /// The recognizer's cumulative scale; the mapper emits the ratio.
    case pinch(scale: CGFloat, centroid: CGPoint)
    case pinchEnded
}

/// Everything the mapper needs to know about the canvas, passed in per event so the mapper itself
/// holds no reference to the model (and the tests need no model).
nonisolated public struct TouchContext {
    public var mode: CanvasMode
    public var transform: CanvasTransform
    /// What lies under a **canvas** point.
    public var hitTest: (CGPoint) -> CanvasHit
    public var isSelected: (CanvasHit) -> Bool

    public init(mode: CanvasMode, transform: CanvasTransform,
                hitTest: @escaping (CGPoint) -> CanvasHit,
                isSelected: @escaping (CanvasHit) -> Bool) {
        self.mode = mode
        self.transform = transform
        self.hitTest = hitTest
        self.isSelected = isSelected
    }
}

/// Touch events → canvas intents (spec §22.2). Pure: no UIKit, no model, no view — which is what
/// makes the whole gesture table testable on macOS.
///
/// The only state is the current drag. A drag stays *pending* until it has travelled
/// `dragThreshold`, then latches onto what was under the press for the rest of the touch: releasing
/// a finger over a different node, or switching mode mid-drag, can never turn a live wire drag into
/// a pan and strand its transaction — the same latching rule `BackgroundDragMode` gives the mouse.
nonisolated public struct TouchIntentMapper {
    /// A drag begins after 6 pt of travel; a tap is a touch that ends inside 6 pt (spec §22.2).
    public static let dragThreshold: CGFloat = 6

    private enum Drag: Equatable {
        case move(CanvasHit)
        case wire
        /// The last cumulative translation reported, so each change emits a delta.
        case pan(last: CGSize)
        /// Canvas coordinates.
        case marquee(start: CGPoint)
    }

    private var drag: Drag?
    /// Where the finger went down, in viewport points: a latch resolves its hit from here, not
    /// from where the finger has travelled to.
    private var pressPoint: CGPoint?
    private var lastTwoFingerTranslation: CGSize?
    private var lastPinchScale: CGFloat?

    public init() {}

    public mutating func map(_ event: TouchEvent, in context: TouchContext) -> [CanvasIntent] {
        switch event {
        case .tap(let p):
            return tap(at: p, in: context)
        case .doubleTap(let p):
            guard case .empty = context.hitTest(context.transform.toCanvas(p)) else { return [] }
            return [.openChooser(at: p)]
        case .longPress(let p):
            return [.contextMenu(at: p, hit: context.hitTest(context.transform.toCanvas(p)))]
        case .dragBegan(let p):
            drag = nil
            pressPoint = p
            return []
        case .dragChanged(let location, let translation):
            return dragChanged(location: location, translation: translation, in: context)
        case .dragEnded(let location, let translation):
            let out = dragEnded(location: location, translation: translation, in: context)
            drag = nil
            pressPoint = nil
            return out
        case .twoFingerPan(let translation):
            let last = lastTwoFingerTranslation ?? .zero
            lastTwoFingerTranslation = translation
            return [.pan(CGSize(width: translation.width - last.width, height: translation.height - last.height))]
        case .twoFingerPanEnded:
            lastTwoFingerTranslation = nil
            return [.endPan]
        case .pinch(let scale, let centroid):
            let last = lastPinchScale ?? 1
            lastPinchScale = scale
            guard last > 0 else { return [] }
            return [.zoom(scale / last, around: centroid)]
        case .pinchEnded:
            lastPinchScale = nil
            return [.endZoom]
        }
    }

    /// A tap never adds in pointer or lasso mode; select mode is the one that toggles. A socket is
    /// too small to aim a tap at, so it counts as its node — a wire drag needs a *drag*.
    private func tap(at p: CGPoint, in c: TouchContext) -> [CanvasIntent] {
        let hit = c.hitTest(c.transform.toCanvas(p))
        let mode: SelectionMode = c.mode == .select ? .toggle : .replace
        switch hit {
        case .node, .comment:
            return [.select(hit, mode)]
        case .socket(let ref, _):
            return [.select(.node(ref.node), mode)]
        case .wire(let ref):
            // The model holds one selected wire, so there is nothing to add to.
            return [.select(.wire(ref), .replace)]
        case .empty:
            // Select mode keeps what you have gathered: a stray tap must not throw it away.
            return c.mode == .select ? [] : [.clearSelection]
        }
    }

    private mutating func dragChanged(location: CGPoint, translation: CGSize,
                                      in c: TouchContext) -> [CanvasIntent] {
        if let drag { return changed(drag, location: location, translation: translation, in: c) }
        guard hypot(translation.width, translation.height) >= Self.dragThreshold else { return [] }
        let start = pressPoint ?? CGPoint(x: location.x - translation.width, y: location.y - translation.height)
        let canvasStart = c.transform.toCanvas(start)
        let hit = c.hitTest(canvasStart)
        switch hit {
        case .node, .comment:
            drag = .move(hit)
            // An unselected item joins the selection *before* the move snapshots its origins;
            // an already-selected one is left alone, so dragging one of five moves all five.
            var out: [CanvasIntent] = c.isSelected(hit) ? [] : [.select(hit, .replace)]
            out.append(.beginMove(hit))
            out.append(.move(translation))
            return out
        case .socket(let ref, let isInput):
            drag = .wire
            return [.beginWire(ref, isInput: isInput), .wire(c.transform.toCanvas(location))]
        case .wire, .empty:
            if c.mode == .pointer {
                drag = .pan(last: translation)
                return [.pan(translation)]
            }
            drag = .marquee(start: canvasStart)
            return [.beginMarquee(canvasStart),
                    .marquee(Self.rect(from: canvasStart, to: c.transform.toCanvas(location)))]
        }
    }

    private mutating func changed(_ drag: Drag, location: CGPoint, translation: CGSize,
                                  in c: TouchContext) -> [CanvasIntent] {
        switch drag {
        case .move:
            return [.move(translation)]
        case .wire:
            return [.wire(c.transform.toCanvas(location))]
        case .pan(let last):
            self.drag = .pan(last: translation)
            return [.pan(CGSize(width: translation.width - last.width, height: translation.height - last.height))]
        case .marquee(let start):
            return [.marquee(Self.rect(from: start, to: c.transform.toCanvas(location)))]
        }
    }

    private func dragEnded(location: CGPoint, translation: CGSize, in c: TouchContext) -> [CanvasIntent] {
        // Never latched: the tap (or double-tap) recognizer owns this touch, and nothing was begun
        // here that has to be ended.
        guard let drag else { return [] }
        switch drag {
        case .move:
            return [.move(translation), .endMove]
        case .wire:
            return [.endWire(c.transform.toCanvas(location))]
        case .pan:
            return [.endPan]
        case .marquee(let start):
            let rect = Self.rect(from: start, to: c.transform.toCanvas(location))
            // Select mode gathers; the lasso is a one-shot selection (spec §22.2).
            return [.endMarquee(rect, c.mode == .lasso ? .replace : .add)]
        }
    }

    private static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }
}
```

- [ ] **Step 8: Run the suites, both app builds, commit**

Run: `swift test --package-path MetalNodesKit` → all green.
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run both `xcodebuild` commands from Global Constraints → `BUILD SUCCEEDED` (macOS and `generic/platform=iOS Simulator`).

```bash
git add MetalNodesKit
git commit -m "feat(ui): CanvasMode and a pure TouchIntentMapper for the iPad canvas" \
           -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 7: `TouchInputOverlay` drives the canvas on iPad

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/InteractiveRect.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/TouchInputOverlayPad.swift` (`#if os(iOS)`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift:22-64` (state), `:83-93` (the catcher slot), `:105-107` (the mouse gestures), `:209` (preferences), `:690-703` (`click(at:)` → `wire(at:)`), plus the new touch section
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift:35-39, 66-76, 90-91, 126-140, 168-176, 190-191, 249-286`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/SocketView.swift:50-58`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/CommentLayer.swift:85-106, 124-149`
- Test: none in the package — see Step 1

The File structure section lists `Canvas/StickyView.swift` and `Canvas/FrameView.swift` under this task; neither needs a change. Their move gesture lives in `CommentLayer.CommentMove` (gated here) and their only interactive chrome is `CommentResizeHandle` (also in `CommentLayer.swift`), so this task leaves both files alone.

**Interfaces:**
- Consumes: `TouchEvent`, `TouchContext`, `TouchIntentMapper`, `CanvasHit`, `CanvasIntent`, `CanvasMode` (T6); `EditorModel.select(_:mode:)`, `.select(nodes:comments:mode:)`, `.selectComment(_:mode:)`, `.clearSelection()`, `.node(at:)`, `.comment(at:)`, `.comments(intersecting:)`, `.selectedWire`; `DropResolver.socket(near:within:anchors:)`, `NodeGeometry.nodes(in:intersecting:shapes:)`, `WireGeometry.distance(from:wireFrom:to:)`.
- Produces: `InteractiveRectKey` + `View.interactiveRect()`; `TouchInputOverlay: UIViewRepresentable` and `TouchOverlayView: UIView` (iOS only); `GraphCanvasView.handleTouch(_:)`, `.apply(_ intent: CanvasIntent)`, `.hit(at:) -> CanvasHit`, `.wire(at:) -> SocketRef?`; `@State contextMenuAnchor: CGPoint?` and `contextMenuHit: CanvasHit?` (written here, consumed by Task 8); accessibility identifiers `canvas`, `node.<8hex>`, `socket.<8hex>.<name>`, `badge.<8hex>`.

- [ ] **Step 1: Record why this task has no unit test**

No test in the package suite can drive this task's code: `UIGestureRecognizer` only fires from real touch delivery inside a running `UIApplication` with a window, so the recognizer callbacks, `hitTest(_:with:)` and the `UIViewRepresentable` update path cannot be exercised from Swift Testing — the logic that *can* be tested was pulled out into `TouchIntentMapper` in Task 6 (tested there) and into `hit(at:)`'s existing helpers (`DropResolver`, `NodeGeometry`, `WireGeometry`, already tested). What remains here is wiring, and the XCUITest target in Task 10 covers it end to end on the iPad Simulator (`pinchZooms`, `lassoSelects`, `longPressOpensTheContextMenu`, `wireDragConnects`, `tapToPlaceOnIPad`). Verification for this task is therefore the package suite (no regressions), the macOS build, the iOS Simulator build, and the Xcode 26.6 macOS build.

- [ ] **Step 2: The interactive-rect preference**

`MetalNodesKit/Sources/MetalNodesUI/Canvas/InteractiveRect.swift` (whole file):

```swift
import SwiftUI

/// Canvas-space rects the touch overlay must hand back to SwiftUI (spec §22.2): param controls,
/// the ◉ viewer badge, comment resize handles. Collected exactly the way socket anchors are, in
/// the "canvas" coordinate space, so the overlay can test a touch against them after converting it
/// with the same transform the canvas draws with.
struct InteractiveRectKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// Reports this view's frame as a region the overlay must not swallow.
    func interactiveRect() -> some View {
        background(GeometryReader { g in
            Color.clear.preference(key: InteractiveRectKey.self, value: [g.frame(in: .named("canvas"))])
        })
    }
}
```

- [ ] **Step 3: Identifiers, interactive rects and the macOS-only gestures in `NodeView`**

`NodeView.body` — the node itself becomes an addressable element for the XCUITest target (spec §22.8):

```swift
    var body: some View {
        Group {
            if shape.style == .dot { dotBody } else { standardBody }
        }
        // `.contain` keeps the params, the badge and the sockets as their own elements inside it,
        // so `node.<hex>` names the node without swallowing what it holds (spec §22.8).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("node.\(GroupCodegen.hex8(node.id))")
    }
```

`standardBody`'s param rows report their rects, and its tap is macOS-only:

```swift
                    if !shape.isPseudo {
                        ForEach(shape.params.filter(\.showsInBody), id: \.name) { param in
                            ParamControl(label: param.label, kind: param.kind,
                                         value: node.params[param.name] ?? param.defaultValue,
                                         onChange: { onChange(.setParam(node.id, param.name, $0)) },
                                         onEditing: onEditing)
                                .interactiveRect()
                        }
                    }
```

```swift
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 6, y: isSelected ? 0 : 3)
        .contentShape(Rectangle())
        #if os(macOS)
        // On iPad the overlay's tap recognizer selects; here the gesture would fight it (spec §22.2).
        .onTapGesture { onSelect(InputModifiers.selectionMode()) }
        #endif
    }
```

`dotBody`'s two socket drags and its move gesture:

```swift
            if let i = shape.inputs.first {
                let inType = resolved?.inputTypes[i.name] ?? concrete(i.type)
                SocketView(type: inType, dimmed: dragType.map { !DropResolver.compatible($0, inType) } ?? false, hitSize: Self.dotSocketHitSize)
                    .opacity(0.001)
                    .socketAnchor(SocketRef(node.id, i.name))
                    #if os(macOS)
                    .gesture(socketDrag(SocketRef(node.id, i.name), isInput: true))
                    #endif
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: -SocketView.size / 2)
            }
            if let o = shape.outputs.first {
                SocketView(type: type, dimmed: dragType != nil, hitSize: Self.dotSocketHitSize)
                    .opacity(0.001)
                    .socketAnchor(SocketRef(node.id, o.name))
                    #if os(macOS)
                    .gesture(socketDrag(SocketRef(node.id, o.name), isInput: false))
                    #endif
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: SocketView.size / 2)
            }
        }
        .frame(width: NodeGeometry.dotSize, height: NodeGeometry.dotSize)
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 4, y: isSelected ? 0 : 2)
        .contentShape(Circle())
        #if os(macOS)
        .gesture(headerDrag)
        #endif
    }
```

The badge keeps its tap on both platforms — the overlay lets it through because it reports a rect:

```swift
            if !shape.outputs.isEmpty && !shape.isPseudo {
                Image(systemName: isViewed ? "circle.circle.fill" : "circle.circle")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(isViewed ? DraculaTheme.viewerFlag.color : DraculaToken.background.color.opacity(0.55))
                    .padding(3)
                    .contentShape(Rectangle())
                    .highPriorityGesture(TapGesture().onEnded { onViewerToggle() })
                    .accessibilityLabel(isViewed ? "Clear viewer" : "View this node")
                    .accessibilityIdentifier("badge.\(GroupCodegen.hex8(node.id))")
                    .interactiveRect()
            }
```

and the header's move gesture goes macOS-only:

```swift
        .foregroundStyle(DraculaToken.background.color)
        .background(accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .contentShape(Rectangle())
        #if os(macOS)
        .gesture(headerDrag)
        #endif
    }
```

`inputRow` — the socket drag is gated and the inline control reports its rect:

```swift
        return HStack(spacing: 6) {
            SocketView(type: type, dimmed: dim)
                .socketAnchor(ref)
                .offset(x: -8 - SocketView.size / 2)
                #if os(macOS)
                .gesture(socketDrag(ref, isInput: true))
                #endif
            if NodeShape.isPlus(decl) {
                plusGlyph
            } else if !wired, !shape.isPseudo, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: coerced(node.params[decl.name] ?? dflt, to: type),
                             onChange: { onChange(.setParam(node.id, decl.name, $0)) },
                             onEditing: onEditing)
                    .interactiveRect()
            } else {
                Text(decl.label).font(.caption)
            }
        }
```

`outputRow`:

```swift
            SocketView(type: type, dimmed: dragType != nil)
                .socketAnchor(ref)
                .offset(x: 8 + SocketView.size / 2)
                #if os(macOS)
                .gesture(socketDrag(ref, isInput: false))
                #endif
        }
```

`headerDrag`, `socketDrag`, `dragging`, `wasSelectedAtStart`, `socketDragging` and `lastHeaderClick` stay compiled on both platforms (they are private and unused on iOS, which is not a warning); only their attachment points are gated, which keeps the diff small and the macOS behaviour byte-for-byte what it was.

- [ ] **Step 4: Socket identifiers**

`SocketView.swift` — the anchor modifier already knows the ref, so the identifier goes there and every socket that reports an anchor is addressable (spec §22.8):

```swift
extension View {
    /// Reports this view's centre, in the "canvas" space, as the anchor for `ref` — and names it
    /// for the XCUITest target, which drags wires between `socket.<hex>.<name>` elements.
    func socketAnchor(_ ref: SocketRef) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named("canvas"))
            Color.clear.preference(key: SocketAnchorKey.self, value: [ref: CGPoint(x: f.midX, y: f.midY)])
        })
        .accessibilityElement()
        .accessibilityIdentifier("socket.\(GroupCodegen.hex8(ref.node)).\(ref.socket)")
    }
}
```

- [ ] **Step 5: Comments — gate the move gesture, keep the resize handle**

`CommentLayer.swift`, `CommentMove.body(content:)`:

```swift
    func body(content: Content) -> some View {
        #if os(macOS)
        content.gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        wasSelectedAtStart = isSelected
                        if !isSelected { actions.select(InputModifiers.selectionMode()) }
                        actions.dragBegan(false)
                    }
                    actions.drag(g.translation)
                }
                .onEnded { g in
                    let wasDragging = dragging
                    dragging = false
                    if wasDragging { actions.dragEnded() }
                    guard abs(g.translation.width) < 1, abs(g.translation.height) < 1, wasSelectedAtStart else { return }
                    let mode = InputModifiers.selectionMode()
                    if mode == .replace || mode == .toggle { actions.select(mode) }
                }
        )
        #else
        // The overlay drives comment selection and movement on iPad (spec §22.2).
        content
        #endif
    }
```

`CommentResizeHandle` keeps its drag on both platforms and reports its rect so the overlay hands the corner back to SwiftUI:

```swift
        .fill(DraculaTheme.selection.color.opacity(0.8))
        .frame(width: Self.size, height: Self.size)
        .contentShape(Rectangle())
        .interactiveRect()
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
```

- [ ] **Step 6: The overlay**

`MetalNodesKit/Sources/MetalNodesUI/Canvas/TouchInputOverlayPad.swift` (whole file):

```swift
#if os(iOS)
import SwiftUI
import UIKit

/// The iPad canvas's single touch target (spec §22.2). It covers the whole viewport above the
/// content and owns every canvas touch except the interactive rects the node and comment views
/// report — those it hands straight back to SwiftUI by failing its own hit test.
///
/// It only *reports*: the recognizer callbacks become `TouchEvent`s and `GraphCanvasView` decides
/// what they mean through `TouchIntentMapper`, so nothing about selection, wiring or undo lives in
/// UIKit.
struct TouchInputOverlay: UIViewRepresentable {
    let transform: CanvasTransform
    /// Canvas-space rects SwiftUI must keep (param controls, the ◉ badge, resize handles).
    let interactiveRects: [CGRect]
    let onEvent: (TouchEvent) -> Void

    /// The box the representable pushes fresh values into on every update: the `UIView` outlives
    /// each `TouchInputOverlay` value, so it must never capture one.
    final class Coordinator {
        var transform: CanvasTransform
        var interactiveRects: [CGRect]
        var onEvent: (TouchEvent) -> Void

        init(transform: CanvasTransform, interactiveRects: [CGRect], onEvent: @escaping (TouchEvent) -> Void) {
            self.transform = transform
            self.interactiveRects = interactiveRects
            self.onEvent = onEvent
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(transform: transform, interactiveRects: interactiveRects, onEvent: onEvent)
    }

    func makeUIView(context: Context) -> TouchOverlayView {
        let view = TouchOverlayView()
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: TouchOverlayView, context: Context) {
        context.coordinator.transform = transform
        context.coordinator.interactiveRects = interactiveRects
        context.coordinator.onEvent = onEvent
        view.coordinator = context.coordinator
    }
}

/// The overlay's view. Six recognizers, all with `cancelsTouchesInView = false` so a touch that
/// falls through to SwiftUI (an interactive rect) is unaffected, and all accepting Pencil touches —
/// a Pencil is a precise finger (spec §22.2).
final class TouchOverlayView: UIView {
    var coordinator: TouchInputOverlay.Coordinator?

    /// Held so the delegate can allow exactly one simultaneous pair: the two-finger pan and the
    /// pinch, which are one gesture to the user.
    private let twoFingerPan = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isMultipleTouchEnabled = true

        let touchTypes: [NSNumber] = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                      NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.minimumNumberOfTouches = 1
        pan.maximumNumberOfTouches = 1

        twoFingerPan.addTarget(self, action: #selector(handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2

        pinch.addTarget(self, action: #selector(handlePinch(_:)))

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        // Otherwise the first tap of a double-tap selects before the chooser opens.
        tap.require(toFail: doubleTap)

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPress.minimumPressDuration = 0.4
        longPress.allowableMovement = TouchIntentMapper.dragThreshold

        for recognizer in [pan, twoFingerPan, pinch, tap, doubleTap, longPress] as [UIGestureRecognizer] {
            recognizer.allowedTouchTypes = touchTypes
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("TouchOverlayView is never loaded from a nib") }

    /// SwiftUI keeps the touches that land in an interactive rect — a param control, the ◉ badge, a
    /// comment's resize handle — and the overlay takes everything else (spec §22.2). The rects are
    /// canvas-space, so the point converts through the same transform the canvas draws with.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point) else { return nil }
        guard let coordinator else { return self }
        let canvasPoint = coordinator.transform.toCanvas(point)
        if coordinator.interactiveRects.contains(where: { $0.contains(canvasPoint) }) { return nil }
        return self
    }

    // MARK: Recognizers → events (viewport coordinates)

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let location = g.location(in: self)
        let t = g.translation(in: self)
        let translation = CGSize(width: t.x, height: t.y)
        switch g.state {
        case .began:
            // `.began` already carries a little travel; report where the finger went *down*, which
            // is the point the mapper resolves the drag's hit from.
            send(.dragBegan(CGPoint(x: location.x - t.x, y: location.y - t.y)))
        case .changed:
            send(.dragChanged(location: location, translation: translation))
        case .ended, .cancelled, .failed:
            // A cancelled drag must still end: the mapper's latch closes the canvas's transaction.
            send(.dragEnded(location: location, translation: translation))
        default:
            break
        }
    }

    @objc private func handleTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began, .changed:
            send(.twoFingerPan(CGSize(width: t.x, height: t.y)))
        case .ended, .cancelled, .failed:
            send(.twoFingerPanEnded)
        default:
            break
        }
    }

    @objc private func handlePinch(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            send(.pinch(scale: g.scale, centroid: g.location(in: self)))
        case .ended, .cancelled, .failed:
            send(.pinchEnded)
        default:
            break
        }
    }

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        send(.tap(g.location(in: self)))
    }

    @objc private func handleDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        send(.doubleTap(g.location(in: self)))
    }

    @objc private func handleLongPress(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        send(.longPress(g.location(in: self)))
    }

    private func send(_ event: TouchEvent) { coordinator?.onEvent(event) }
}

extension TouchOverlayView: UIGestureRecognizerDelegate {
    /// Only the two-finger pan and the pinch run together — a two-finger gesture that both moves
    /// and spreads is one motion. Everything else stays exclusive, so a tap can never fire in the
    /// middle of a drag.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let pair = Set([ObjectIdentifier(g), ObjectIdentifier(other)])
        return pair == Set([ObjectIdentifier(twoFingerPan), ObjectIdentifier(pinch)])
    }
}
#endif
```

- [ ] **Step 7: Wire the canvas to the overlay**

`GraphCanvasView.swift` — new state, after `lastClick`:

```swift
    @State private var lastClick: (time: Date, point: CGPoint)?
    /// The touch path (spec §22.2). Compiled on both platforms — the mapper is pure and the rects
    /// cost nothing when nothing feeds them — but only iOS ever sends it an event.
    @State private var mapper = TouchIntentMapper()
    @State private var interactiveRects: [CGRect] = []
    /// What a touch move is dragging, so `move` and `endMove` route to the comment functions or
    /// the node functions the way the two mouse gestures do.
    @State private var activeMove: CanvasHit?
    /// Where a long-press asked for the context menu, and what it hit. Stored here and presented
    /// by Task 8.
    @State private var contextMenuAnchor: CGPoint?
    @State private var contextMenuHit: CanvasHit?
```

The `ScrollWheelCatcher` slot gains the overlay's `#else` branch:

```swift
                marqueeOverlay
                #if os(macOS)
                ScrollWheelCatcher { delta, location, cmd, precise in
                    if cmd {
                        transform.zoom(by: zoomFactor(for: delta, precise: precise), around: location)
                    } else {
                        transform.pan(by: delta)
                    }
                    model.viewState.cameras[model.activePath] = transform.camera
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                #else
                TouchInputOverlay(transform: transform, interactiveRects: interactiveRects,
                                  onEvent: handleTouch)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                #endif
```

The canvas names itself and stops attaching the mouse gestures on iOS:

```swift
            .contentShape(Rectangle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas")
            #if os(macOS)
            .gesture(backgroundDrag)
            .simultaneousGesture(magnifyGesture)
            #endif
            .focusable()
```

and collects the rects next to the anchors:

```swift
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        #if os(iOS)
        .onPreferenceChange(InteractiveRectKey.self) { interactiveRects = $0 }
        #endif
```

- [ ] **Step 8: Extract `wire(at:)` and add the touch section**

`click(at:)` splits, so the touch path can ask the same question the mouse path answers:

```swift
    /// The wire within grabbing distance of a canvas point, nearest first. Lifted out of
    /// `click(at:)` so `hit(at:)` resolves wires exactly as a click does (spec §22.2).
    private func wire(at p: CGPoint) -> SocketRef? {
        var best: (SocketRef, CGFloat)?
        for (to, from) in model.graph.inputs {
            guard let a = anchor(from), let b = anchor(to) else { continue }
            let d = WireGeometry.distance(from: p, wireFrom: a, to: b)
            if d <= Self.wireHitDistance / transform.zoom && (best == nil || d < best!.1) { best = (to, d) }
        }
        return best?.0
    }

    private func click(at p: CGPoint) {
        if let wire = wire(at: p) {
            model.selection = []
            model.selectedWire = wire
        } else {
            model.clearSelection()
        }
    }
```

The touch section, at the end of `GraphCanvasView` (before the closing brace):

```swift
    // MARK: Touch (spec §22.2)

    /// What a canvas point belongs to, resolved in the order the mouse path resolves things:
    /// socket (only where socket drags exist at all — not in compact LOD), node, comment, wire,
    /// nothing. Shared by taps, drags and the long-press menu.
    private func hit(at p: CGPoint) -> CanvasHit {
        if transform.zoom >= Self.lodZoom,
           let ref = DropResolver.socket(near: p, within: SocketView.hitSize / 2 / transform.zoom, anchors: anchors),
           let node = model.graph.nodes[ref.node], let shape = model.shape(of: node) {
            return .socket(ref, isInput: shape.input(named: ref.socket) != nil)
        }
        if let id = model.node(at: p) { return .node(id) }
        if let id = model.comment(at: p) { return .comment(id) }
        if let ref = wire(at: p) { return .wire(ref) }
        return .empty
    }

    private func isSelected(_ hit: CanvasHit) -> Bool {
        switch hit {
        case .node(let id): model.selection.contains(id)
        case .comment(let id): model.selectedComments.contains(id)
        case .socket(let ref, _): model.selection.contains(ref.node)
        case .wire(let ref): model.selectedWire == ref
        case .empty: false
        }
    }

    /// Every canvas touch on iPad: the overlay's event becomes intents, and each intent runs the
    /// function the mouse path already calls. Nothing here is platform-specific but its caller.
    private func handleTouch(_ event: TouchEvent) {
        canvasFocused = true
        let context = TouchContext(mode: model.viewState.canvasMode, transform: transform,
                                   hitTest: { hit(at: $0) }, isSelected: { isSelected($0) })
        for intent in mapper.map(event, in: context) { apply(intent) }
    }

    private func apply(_ intent: CanvasIntent) {
        switch intent {
        case .select(let hit, let mode):
            switch hit {
            case .node(let id): model.select(id, mode: mode)
            case .comment(let id): model.selectComment(id, mode: mode)
            case .socket(let ref, _): model.select(ref.node, mode: mode)
            // Exactly what `click(at:)` does for a wire.
            case .wire(let ref): model.selection = []; model.selectedWire = ref
            case .empty: model.clearSelection()
            }
        case .clearSelection:
            model.clearSelection()
        case .beginMove(let hit):
            activeMove = hit
            // The mapper only ever latches a move onto a node or a comment.
            if case .comment(let id) = hit { beginCommentDrag(id, resizing: false) } else { beginNodeDrag() }
        case .move(let t):
            if case .comment = activeMove { dragComments(by: t) } else { moveSelection(by: t) }
        case .endMove:
            if case .comment = activeMove { endCommentDrag() } else { endNodeDrag() }
            activeMove = nil
        case .beginWire(let ref, let isInput):
            beginWire(from: ref, isInput: isInput)
        case .wire(let p):
            pendingWire?.point = p
        case .endWire(let p):
            // Closes the drag's transaction — or opens the chooser, which owns it from there.
            endWire(at: p)
        case .beginMarquee(let p):
            marqueeStart = p
            marquee = CGRect(origin: p, size: .zero)
        case .marquee(let r):
            marquee = r
        case .endMarquee(let r, let mode):
            marqueeStart = nil
            marquee = nil
            // Nodes and comments in one pass, so neither clears the other (spec §21.4).
            let nodes = NodeGeometry.nodes(in: model.graph, intersecting: r, shapes: shapes)
            model.select(nodes: nodes, comments: model.comments(intersecting: r), mode: mode)
        case .pan(let delta):
            transform.pan(by: delta)
        case .endPan:
            model.viewState.cameras[model.activePath] = transform.camera
        case .zoom(let factor, let point):
            transform.zoom(by: factor, around: point)
        case .endZoom:
            model.viewState.cameras[model.activePath] = transform.camera
        case .contextMenu(let p, let hit):
            contextMenuHit = hit
            contextMenuAnchor = p
        case .openChooser(let p):
            openChooser(atScreen: p, wire: nil)
        }
    }
```

Two behaviours the touch path deliberately does not reproduce: the ⌥-drag duplicate (there is no Option on iPad, spec §11.2 — `beginNodeDrag` reads `InputModifiers.optionHeld`, which is `false` on iOS) and the double-click dive into a group instance (double-tap belongs to the chooser; Edit Group in the context menu dives, Task 8).

- [ ] **Step 9: Run the suites and all four builds, commit**

Run: `swift test --package-path MetalNodesKit` → all green (the package suite must be unchanged by this task).
Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → prints nothing.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO` → `BUILD SUCCEEDED`.
This diff stores a closure in a view (`TouchInputOverlay.onEvent`, and the two closures in `TouchContext`), so also run the Xcode 26.6 macOS build (the Swift 6.2 IRGen crash of PR #7):
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build` → `BUILD SUCCEEDED`.

If Xcode's MCP was used at any point: `git checkout -- MetalNodes.xcodeproj/project.pbxproj` before committing — no project file change belongs to this task.

```bash
git add MetalNodesKit
git commit -m "feat(ui): touch input overlay drives the canvas on iPad" \
           -m "Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---
### Task 8: iPad layout, toolbar and the canvas context menu

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/CanvasContextMenu.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorViewPad.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift:7-17` (two `CanvasRequest` cases)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (the `onChange(of: model.canvasRequest)` switch at `:218-247`, the context-menu anchor T7 writes, the macOS `.contextMenu` and the iOS `.popover`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift:42-57, 83-90` (`split`, the iOS `previewColumn`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Palette/PaletteView.swift:44-71`
- Create: `MetalNodes/SamplePackage.swift`
- Modify: `MetalNodes/MetalNodesApp.swift:36-54`, `MetalNodes/DocumentHostView.swift`

**Interfaces:**
- Consumes: `CanvasHit` (T6), `EditorServices` / `EditorView.init(model:device:services:)` (T4), `ExporterPad.temporaryShareURLs(files:name:)` (T5), `EditorViewState.canvasMode` / `.showsInspector` (T6), `GraphCanvasView.openChooser(atScreen:wire:)`, `EditorModel.paste(at:)`, `.addSticky(centredAt:)`, `.firstOutput(of:)`, `.toggleViewer(_:)`, `.canCopy`, `.canPaste`, `.editableSelection`, `.selectedInstance`, `.canExitGroup`, `.canUndo` / `.canRedo`.
- Produces: `CanvasRequest.paste`, `CanvasRequest.openChooser`; `struct CanvasContextMenu: View { let model: EditorModel; let canvasPoint: CGPoint; let hit: CanvasHit? }`; `struct EditorViewPad<Inspector: View>: View` with `init(model:device:services:inspector:)`; `GraphCanvasView.ContextMenuAnchor`; `enum SamplePackage { static func writeTemporary() throws -> URL }` (app target).

**Refinement of the contract, recorded here as a ruling:** `EditorViewPad` takes the preview/inspector column as a `@ViewBuilder` (`init(model:device:services:inspector:)`) rather than rebuilding it. `EditorView.previewPane` owns the preview's mouse uniform, the viewer range fields, the notice line, the diagnostics list and `InspectorView`; duplicating ~50 lines of it in a Pad file would be a second place for every future preview change to be made. Cost if wrong: one generic parameter on a view that is constructed in exactly one place.

**No new unit test in this task.** `NavigationSplitView`, `.inspector`, `.toolbar` and `.contextMenu` have no headless surface in the package suite, and the two new `CanvasRequest` cases are tested in Task 9. What proves this task: both app builds, Task 10's XCUITests (`tapToPlaceOnIPad`, `longPressOpensTheContextMenu`) and Task 11's checks 1, 12, 13, 14, 15, 18, 19.

- [ ] **Step 1: The two new canvas requests**

`EditorModel.swift` — append to `CanvasRequest`, after `case addSticky`:

```swift
    /// Paste at the viewport's centre (spec §22.5). iPad's Edit ▸ Paste has no pointer location to
    /// land at, and only the canvas knows where its centre is; macOS keeps pasting at the pointer
    /// through `onPasteCommand`.
    case paste
    /// Open the node chooser at the viewport's centre — the toolbar's ✛ (spec §22.3).
    case openChooser
```

- [ ] **Step 2: `CanvasContextMenu.swift`**

```swift
import SwiftUI
import CoreGraphics
import MetalNodesCore

/// The canvas context menu (spec §22.3) — long-press on iPad, right-click on macOS, one view, so
/// the two platforms cannot drift apart. Every item enables exactly as its `EditorCommands`
/// counterpart minus the `canvasHasFocus` gate: a menu the canvas itself put on screen is proof
/// enough that the canvas, not a text field, is what the gesture addressed.
struct CanvasContextMenu: View {
    let model: EditorModel
    /// Canvas coordinates: where Paste lands and where a new sticky note is centred.
    let canvasPoint: CGPoint
    /// What the press landed on, for the viewer items. `nil` on macOS, where the menu comes from
    /// the pointer and the ◉ badge is one click away anyway.
    let hit: CanvasHit?

    /// The iPad menu is a popover this view is the content of, so each item has to close it; the
    /// macOS `.contextMenu` closes itself, and calling `dismiss()` in a window's root hierarchy
    /// there would close the *window*. Hence the platform gate rather than a bare `dismiss()`.
    #if os(iOS)
    @Environment(\.dismiss) private var dismiss
    #endif

    private func act(_ body: () -> Void) {
        body()
        #if os(iOS)
        dismiss()
        #endif
    }

    var body: some View {
        Button("Cut") { act { model.cutSelection() } }
            .disabled(!model.canCopy)
        Button("Copy") { act { model.copySelection() } }
            .disabled(!model.canCopy)
        Button("Paste") { act { model.paste(at: canvasPoint) } }
            .disabled(!model.canPaste)
        Button("Duplicate") { act { model.duplicateSelection() } }
            .disabled(!model.canCopy)
        Button("Delete") { act { model.deleteSelection() } }
            .disabled(model.selection.isEmpty && model.selectedComments.isEmpty && model.selectedWire == nil)
        Divider()
        Button("Group") { act { model.groupSelection() } }
            .disabled(model.editableSelection.isEmpty)
        Button("Ungroup") { act { model.ungroupSelection() } }
            .disabled(model.selectedInstance == nil)
        Button("Make Unique") { act { model.makeUniqueSelection() } }
            .disabled(model.selectedInstance == nil)
        Button("Edit Group") { act { if let id = model.selectedInstance { model.diveIn(id) } } }
            .disabled(model.selectedInstance == nil)
        Button("Exit Group") { act { model.exitGroup() } }
            .disabled(!model.canExitGroup)
        Divider()
        Button("Frame Selection") { act { model.frameSelection() } }
            .disabled(model.selection.isEmpty)
        Button("Add Sticky Note") { act { model.addSticky(centredAt: canvasPoint) } }
        if let ref = viewerSocket {
            Divider()
            Button(model.viewer == ref ? "Clear Viewer" : "Set Viewer") { act { model.toggleViewer(ref) } }
        }
    }

    /// The socket the viewer items act on. A viewer is always an *output*, so pressing an input
    /// socket — or a node body — views that node's first output, exactly what the ◉ badge and ⌘⇧V
    /// use (`firstOutput`).
    private var viewerSocket: SocketRef? {
        switch hit {
        case .socket(let ref, let isInput)?: isInput ? model.firstOutput(of: ref.node) : ref
        case .node(let id)?: model.firstOutput(of: id)
        default: nil
        }
    }
}
```

- [ ] **Step 3: The canvas presents it on both platforms**

`GraphCanvasView.swift`, three edits.

(a) Replace the state T7 left for the anchor — `@State private var contextMenuAnchor: CGPoint?` — with an identified value, because `.popover(item:)` needs an identity and the menu needs the hit as well as the point:

```swift
    /// The long-press menu's anchor (spec §22.3): where the popover points, where Paste lands, and
    /// what the press hit. A fresh `id` per press is what re-presents the popover at a new point.
    struct ContextMenuAnchor: Identifiable {
        let id = UUID()
        var screenPoint: CGPoint      // viewport coords
        var canvasPoint: CGPoint
        var hit: CanvasHit
    }
    @State private var contextMenuAnchor: ContextMenuAnchor?
```

and in T7's `handleTouch(_:)` the `case .contextMenu(let p, let h):` body becomes the single line

```swift
            contextMenuAnchor = ContextMenuAnchor(screenPoint: p, canvasPoint: transform.toCanvas(p), hit: h)
```

That is the only line of T7's `handleTouch` this task edits.

(b) In the `onChange(of: model.canvasRequest)` switch, after the `case .addSticky:` block and before `case .fitAll:`:

```swift
            case .paste:
                // Edit ▸ Paste on iPad (spec §22.5): the viewport's centre, in canvas coordinates.
                guard viewport != .zero else { return }
                model.paste(at: transform.toCanvas(CGPoint(x: viewport.width / 2, y: viewport.height / 2)))
                return
            case .openChooser:
                // The toolbar's ✛ (spec §22.3) — the same chooser ⇧A opens, at the centre instead
                // of at the pointer.
                guard viewport != .zero else { return }
                openChooser(atScreen: CGPoint(x: viewport.width / 2, y: viewport.height / 2), wire: nil)
                return
```

(c) Attach the menus. Immediately after the existing `.contentShape(Rectangle())` line (the one before `.gesture(backgroundDrag)`), add:

```swift
            #if os(macOS)
            // Parity with the iPad long-press (spec §22.3). `hoverLocation` is where the pointer
            // was when the menu opened, so Paste lands under the cursor like ⌘V does.
            .contextMenu {
                CanvasContextMenu(model: model, canvasPoint: transform.toCanvas(hoverLocation), hit: nil)
            }
            #else
            // The long-press menu. A popover rather than SwiftUI's `.contextMenu`, because the
            // touch overlay owns the long-press and never lets SwiftUI's recognizer see it. It and
            // the node chooser are mutually exclusive: both are opened by `handleTouch`, which
            // emits `contextMenu` or `openChooser` for one gesture, never both.
            .popover(item: $contextMenuAnchor,
                     attachmentAnchor: .rect(.rect(CGRect(origin: contextMenuAnchor?.screenPoint ?? .zero,
                                                          size: CGSize(width: 1, height: 1)))),
                     arrowEdge: .top) { anchor in
                VStack(alignment: .leading, spacing: 6) {
                    CanvasContextMenu(model: model, canvasPoint: anchor.canvasPoint, hit: anchor.hit)
                        .buttonStyle(.borderless)
                }
                .padding(12)
                .frame(width: 220)
                .background(DraculaToken.background.color)
                .presentationCompactAdaptation(.popover)
            }
            #endif
```

- [ ] **Step 4: `EditorViewPad.swift`**

```swift
#if os(iOS)
import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

/// The iPad editor (spec §22.3): the palette as the split view's sidebar, breadcrumb over canvas
/// as the detail, and the preview / inspector / code column as a trailing inspector. The inspector
/// content is passed in rather than rebuilt — it is `EditorView.previewColumn`, unchanged.
struct EditorViewPad<Inspector: View>: View {
    let model: EditorModel
    let device: MTLDevice
    let services: EditorServices
    @ViewBuilder let inspector: () -> Inspector

    /// Slide Over and a narrow Split View are compact; M6 supports regular width only (spec §22.3).
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if sizeClass == .compact {
            ContentUnavailableView("MetalNodes needs a wider window",
                                   systemImage: "rectangle.split.3x1",
                                   description: Text("Open MetalNodes full screen, or widen the Split View, to edit this shader. The document stays open."))
        } else {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                PaletteView(model: model)
                    .navigationTitle("Nodes")
                    .navigationBarTitleDisplayMode(.inline)
            } detail: {
                VStack(spacing: 0) {
                    BreadcrumbBar(model: model)
                    GraphCanvasView(model: model)
                }
                .toolbar { toolbarItems }
                .inspector(isPresented: Binding(get: { model.viewState.showsInspector },
                                                set: { model.viewState.showsInspector = $0 })) {
                    inspector()
                        .inspectorColumnWidth(380)
                }
            }
            .navigationSplitViewStyle(.balanced)
        }
    }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { model.requestCanvas(.openChooser) } label: {
                Label("Add Node", systemImage: "plus")
            }
            .accessibilityIdentifier("toolbar.add")

            Picker("Canvas Mode", selection: Binding(get: { model.viewState.canvasMode },
                                                     set: { model.viewState.canvasMode = $0 })) {
                Label("Pointer", systemImage: "cursorarrow").tag(CanvasMode.pointer)
                Label("Select", systemImage: "plus.square.dashed").tag(CanvasMode.select)
                Label("Lasso", systemImage: "lasso").tag(CanvasMode.lasso)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("toolbar.mode")

            // One button for both fits, like the two menu items: with a selection it frames the
            // selection, otherwise the whole graph (spec §22.3).
            Button { model.requestCanvas(model.selection.isEmpty ? .fitAll : .fitSelection) } label: {
                Label("Zoom to Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .accessibilityIdentifier("toolbar.fit")

            Button { model.undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
            Button { model.redo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .disabled(!model.canRedo)

            Button { model.viewState.showsInspector.toggle() } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .accessibilityIdentifier("toolbar.inspector")

            exportMenu
        }
    }

    /// Export (spec §22.4). "Export to Files…" goes through `exportRequest` → `EditorView` →
    /// `services.exporter`, the same path the macOS save panel uses; Share hands the same files to
    /// `ShareLink` from a temporary directory. The URLs are computed in the menu's content, so
    /// nothing is written to disk until the menu is actually opened.
    private var exportMenu: some View {
        Menu {
            Button("Export to Files…") { model.requestExport() }
            if let urls = shareURLs {
                ShareLink("Share…", items: urls)
            }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .accessibilityIdentifier("toolbar.export")
    }

    /// `nil` — so the menu shows only "Export to Files…" — when the graph has errors, or when the
    /// injected exporter is a test double rather than the Pad presenter.
    private var shareURLs: [URL]? {
        guard let pad = services.exporter as? ExporterPad,
              let files = try? model.exportFiles() else { return nil }
        return try? pad.temporaryShareURLs(files: files, name: model.document.settings.exportName)
    }
}
#endif
```

- [ ] **Step 5: `EditorView` picks the layout**

`EditorView.swift` — replace the whole of `private var split` with:

```swift
    /// macOS: three columns in an `HSplitView`. iPad: `EditorViewPad` (spec §22.3), which takes
    /// this same `previewColumn` as its trailing inspector.
    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            PaletteView(model: model).frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
            canvasColumn.frame(minWidth: 480)
            previewColumn.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        EditorViewPad(model: model, device: device, services: services) { previewColumn }
        #endif
    }
```

and, in `previewColumn`'s `#else` branch, give the code panel the fixed height §22.3 asks for inside the inspector column:

```swift
        VStack(spacing: 0) {
            previewPane
            if model.viewState.showsCode {
                CodePanel(model: model).frame(height: 260)
            }
        }
```

`canvasColumn` stays as it is: the macOS branch is its only caller now, and `EditorViewPad` builds the same two-view stack itself because it has to hang the toolbar and the inspector off the detail column.

- [ ] **Step 6: Palette rows place on one tap on iOS**

`PaletteView.swift` — `row(_:)` and `definitionRow(_:)` end with:

```swift
        .contentShape(Rectangle())
        .accessibilityIdentifier("palette.\(def.id)")
        .draggable(NodeDefTransfer(defID: def.id))
        // One tap places on iPad (spec §22.3); a double-click still places on macOS, where a
        // single click is what selects a row.
        #if os(macOS)
        .onTapGesture(count: 2) { model.requestCanvas(.place(defID: def.id)) }
        #else
        .onTapGesture { model.requestCanvas(.place(defID: def.id)) }
        #endif
```

```swift
        .contentShape(Rectangle())
        .draggable(NodeDefTransfer(groupID: def.id))
        #if os(macOS)
        .onTapGesture(count: 2) { model.requestCanvas(.placeGroup(def.id)) }
        #else
        .onTapGesture { model.requestCanvas(.placeGroup(def.id)) }
        #endif
```

Only the builtin rows carry an identifier: `palette.<nodeid>` is what §22.8 lists, and a definition's id is a fresh UUID per document — nothing a test could name. The `#if` inside the modifier chain is safe because only one branch is ever compiled, so `row`'s opaque return type is a single concrete type per platform.

- [ ] **Step 7: "Open Sample Shader" on iPad, one implementation for both platforms**

Create `MetalNodes/SamplePackage.swift`:

```swift
import Foundation
import MetalNodesCore

/// Help ▸ Open Sample Shader (macOS) and the document toolbar's item (iPad), spec §22.4. The
/// sample is written to a fresh temporary package and opened as an ordinary document, so editing
/// it never touches anything the user owns and both platforms open the identical file.
enum SamplePackage {
    static func writeTemporary() throws -> URL {
        let directory = URL.temporaryDirectory
            .appending(path: "Samples/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "Sample.mnshader")
        try ShaderPackage(document: .sample()).fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }
}
```

`MetalNodesApp.swift` — `openSample()` loses the temp-writing:

```swift
    #if os(macOS)
    /// Opens the sample as a document, so Help ▸ Open Sample Shader lands in the same editor as
    /// any other file — and editing it never touches the original.
    private func openSample() {
        do {
            let url = try SamplePackage.writeTemporary()
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSAlert(error: error).runModal() }
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    #endif
```

`DocumentHostView.swift` — add the iOS state next to the existing properties:

```swift
    #if os(iOS)
    @Environment(\.openDocument) private var openDocument
    @State private var sampleError: String?
    #endif
```

attach the toolbar item and its alert after the existing `.onChange(of: undoManager) { … }` modifier (and before the macOS-only `.frame(minWidth:minHeight:)` T2 leaves in place):

```swift
        #if os(iOS)
        // iPad has no Help menu; the sample rides the document's toolbar overflow (spec §22.4).
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button("Open Sample Shader", systemImage: "sparkles") { openSample() }
            }
        }
        .alert("Could not open the sample", isPresented: Binding(get: { sampleError != nil },
                                                                set: { if !$0 { sampleError = nil } })) {
            Button("OK") { sampleError = nil }
        } message: { Text(sampleError ?? "") }
        #endif
```

and the action:

```swift
    #if os(iOS)
    /// `openDocument` hands the URL to the document browser, which opens it in its own scene —
    /// exactly what tapping the file in Files would do.
    private func openSample() {
        Task {
            do { try await openDocument(at: SamplePackage.writeTemporary()) }
            catch { sampleError = error.localizedDescription }
        }
    }
    #endif
```

- [ ] **Step 8: Run everything and commit**

Run: `swift test --package-path MetalNodesKit` → green; `swift build --package-path MetalNodesKit 2>&1 | grep -i warning` → nothing.
Run both `xcodebuild` commands from Global Constraints → `BUILD SUCCEEDED`.
This diff stores closures in views (the toolbar items, the menu buttons), so also run the macOS build under Xcode 26.6:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build
```

```bash
git add MetalNodesKit MetalNodes
git commit -m "$(cat <<'EOF'
feat(ui): iPad layout — split view, inspector, toolbar, context menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---

### Task 9: Hardware keyboard and the Edit menu on iPad

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift:47` (a new group before the existing `CommandGroup(after: .pasteboard)`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Palette/NodeSearchPopover.swift` — **no code change**; Step 3 records what was verified instead
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift` (append one `@Test`)

**Interfaces:**
- Consumes: `CanvasRequest.paste` / `.openChooser` and their canvas handling (Task 8), `EditorModel.cutSelection()`, `.copySelection()`, `.deleteSelection()`, `.selectAll()`, `.canCopy`, `.canPaste`, `.canvasHasFocus`.
- Produces: nothing new; the iOS branch of `EditorCommands.body`.

**Ruling — the plan deviates from spec §22.5.** §22.5 asks for a `UIViewRepresentable` first responder behind the canvas (`EditActionsPad.swift`) implementing `cut:`, `copy:`, `paste:`, `selectAll:` and `delete:`, mirroring the responder-selector approach macOS uses in §18.6. This plan instead adds a SwiftUI `CommandGroup(replacing: .pasteboard)` under `#if os(iOS)`. Reasons: on iPadOS 27 the menu bar and the ⌘ HUD are built from the same `Commands` tree that already carries Export, Undo/Redo, Duplicate, the five group items and the whole View menu, so a second, responder-based path would duplicate every enablement rule and could disagree with it; and `canvasHasFocus` — which the canvas already publishes through `.focused($canvasFocused)` on both platforms — is what keeps these key equivalents out of a focused `TextField`'s way, which is the only thing the responder chain bought on macOS. What it costs if wrong: a focused text field's own Cut/Copy/Paste come from UIKit's edit menu rather than from this group, so the two never contend, but ⌘X in a field goes through UIKit while the canvas item sits disabled — if that ever misbehaves the responder view from §22.5 is still the fallback. **No unit test can instantiate a `Commands` tree**; Task 11 check 14 verifies every key by hand, and Step 1 below tests the two model-level requests those keys route through.

- [ ] **Step 1: Write the failing test**

Append to `EditorModelTests.swift` (inside `@Suite struct EditorModelTests`):

```swift
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
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter pasteAndChooserRequestsRoundTripThroughCanvasRequest`
Expected: FAIL if Task 8 has not landed (`CanvasRequest` has no `paste` / `openChooser`); with Task 8 landed this test passes immediately and is a regression guard for the two cases — record which of the two it was.

- [ ] **Step 3: The iOS Edit-menu group**

`EditorCommands.swift` — insert **before** the existing `CommandGroup(after: .pasteboard)`:

```swift
        // iPad's Edit ▸ Cut / Copy / Paste / Delete / Select All (spec §22.5, and the ruling in the
        // M6 plan's Task 9: SwiftUI Commands, not a UIKit responder). macOS keeps the responder
        // selectors on the canvas — `onCommand(#selector(NSText.cut(_:)))` and friends — so its
        // pasteboard group stays the system's.
        //
        // Gated on `canvasFocused` for the same reason every other item is: while a node parameter
        // `TextField` has the focus these key equivalents go disabled, and the field's own editing
        // commands see the keystroke instead.
        #if os(iOS)
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { model?.cutSelection() }
                .keyboardShortcut("x", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canCopy ?? false))
            Button("Copy") { model?.copySelection() }
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canCopy ?? false))
            // At the viewport's centre, which only the canvas knows (spec §22.5).
            Button("Paste") { model?.requestCanvas(.paste) }
                .keyboardShortcut("v", modifiers: .command)
                .disabled(!canvasFocused || !(model?.canPaste ?? false))
            Button("Delete") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!canvasFocused)
            Button("Select All") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
                .disabled(!canvasFocused)
        }
        #endif
```

`NodeSearchPopover` needs no change and gets none: `.onAppear { fieldFocused = true }` already raises the software keyboard and takes the field on iPad, `.onKeyPress(.escape)` already cancels from a hardware keyboard, the arrow keys already move the highlight, and `.onExitCommand` stays `#if os(macOS)` because `cancelOperation:` is an AppKit selector. What is left to confirm by hand is that the popover keeps that focus while the software keyboard animates in — Task 11 check 11.

- [ ] **Step 4: Run the suite, both builds, commit**

Run: `swift test --package-path MetalNodesKit` → green. Both `xcodebuild` commands → `BUILD SUCCEEDED`. This diff stores closures in a `Commands` tree, so also run the macOS build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

```bash
git add MetalNodesKit
git commit -m "$(cat <<'EOF'
feat(ui): Edit menu and hardware-keyboard commands on iPad

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---

### Task 10: `MetalNodesAppUITests` — the XCUITest target

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/StarterDocuments.swift` (add `textured()`)
- Create: `MetalNodes/LaunchFixture.swift`
- Modify: `MetalNodes/MetalNodesApp.swift:23` (the `DocumentGroup`'s new document)
- Create: `MetalNodesAppUITests/MetalNodesAppUITests.swift`
- Modify: `MetalNodes.xcodeproj/project.pbxproj`
- Create: `MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ShaderDocumentTests.swift` (one `@Test` for the fixture), and the XCUITest file itself

**Interfaces:**
- Consumes: accessibility identifiers from T7 (`canvas`, `node.<8hex>`, `socket.<8hex>.<name>`, `badge.<8hex>`) and Task 8 (`palette.<nodeid>`, `toolbar.*`), `EditorViewState.canvasMode` (T6).
- Produces: `ShaderDocument.textured()`; `enum LaunchFixture { static func document() -> ShaderDocument }` (app target); the `MetalNodesAppUITests` target and the shared `MetalNodes` scheme.

**Ruling — the fixture's node ids.** The contract's ids `00000000-0000-0000-0000-0000000001{01,02,03}` differ only in their *last* group, but `GroupCodegen.hex8` — and therefore every `node.<8hex>` / `socket.<8hex>.<name>` identifier — is the **first** eight characters of the UUID string. All three nodes would be `node.00000000`, and `socket.00000000.uv` would match both the UV node's output and the Texture Sample's input. The fixture therefore moves the same digits into the first group: `00000101-…`, `00000102-…`, `00000103-…`, giving `node.00000101` / `node.00000102` / `node.00000103`. Cost if wrong: three literals.

**Ruling — the wire-drag test's endpoints.** The contract's "drag `socket.<hex>.uv` to a Fragment Output body" would ask the auto-connect for a `float2` → `color` conversion. The fixture instead leaves the Texture Sample's `color` output unconnected, and the test drags `socket.00000102.color` onto `node.00000103`, an exact type match with one obvious target input. Cost if wrong: one identifier in one test.

**Finder → canvas image drop stays a hand check.** XCUITest cannot drive a drag that starts in another application, so the M5 carry-over ("owed to a human — check 5") is *not* retired by this target; it stays in Task 11's macOS regression subset as M5 item 5.

- [ ] **Step 1: Write the failing fixture test**

Append to `ShaderDocumentTests.swift`:

```swift
    /// The XCUITest fixture (spec §22.8). Its ids are fixed *and distinct in their first eight hex
    /// digits*, because that prefix is what `GroupCodegen.hex8` — and every accessibility
    /// identifier built from it — uses. The Texture Sample's `color` output is deliberately
    /// unconnected: it is what the wire-drag UI test connects.
    @Test func texturedFixtureHasStableIdentifiers() {
        let doc = ShaderDocument.textured()
        let uv = NodeID(raw: UUID(uuidString: "00000101-0000-0000-0000-000000000000")!)
        let tex = NodeID(raw: UUID(uuidString: "00000102-0000-0000-0000-000000000000")!)
        let out = NodeID(raw: UUID(uuidString: "00000103-0000-0000-0000-000000000000")!)
        #expect(Set(doc.root.nodes.keys) == Set([uv, tex, out]))
        #expect(doc.root.nodes[tex]?.kind == .builtin("texture.sample"))
        #expect(doc.root.inputs[SocketRef(tex, "uv")] == SocketRef(uv, "uv"))
        #expect(doc.root.inputs[SocketRef(out, "color")] == nil)
        #expect(Set([uv, tex, out].map(GroupCodegen.hex8)) == Set(["00000101", "00000102", "00000103"]))
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter texturedFixtureHasStableIdentifiers`
Expected: FAIL — `ShaderDocument.textured()` does not exist.

- [ ] **Step 3: The fixture document**

`StarterDocuments.swift` — append inside the existing `public extension ShaderDocument`:

```swift
    /// The `-mnFixture textured` document (spec §22.8): UV → Texture Sample (no asset yet) →
    /// Fragment Output, the last wire left for the UI test to draw. Node ids are fixed so a test
    /// can address `node.<8hex>` and `socket.<8hex>.<name>`; they differ in their first eight hex
    /// digits because that is exactly the prefix `GroupCodegen.hex8` takes.
    static func textured() -> ShaderDocument {
        func id(_ s: String) -> NodeID { NodeID(raw: UUID(uuidString: s)!) }
        let uv = NodeInstance(id: id("00000101-0000-0000-0000-000000000000"),
                              kind: .builtin("input.uv"), position: CGPoint(x: 0, y: 0))
        let tex = NodeInstance(id: id("00000102-0000-0000-0000-000000000000"),
                               kind: .builtin("texture.sample"), position: CGPoint(x: 300, y: 0),
                               params: ["asset": .asset(nil)])
        let out = NodeInstance(id: id("00000103-0000-0000-0000-000000000000"),
                               kind: .builtin("output.fragment"), position: CGPoint(x: 620, y: 0))

        var g = Graph()
        for n in [uv, tex, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(tex.id, "uv"))

        var doc = ShaderDocument()
        doc.root = g
        return doc
    }
```

Run: `swift test --package-path MetalNodesKit --filter texturedFixtureHasStableIdentifiers` → green.

- [ ] **Step 4: `-mnFixture` in the app**

Create `MetalNodes/LaunchFixture.swift`:

```swift
import Foundation
import MetalNodesCore

/// What File ▸ New — and, on iPad, the document browser's Create Document — starts from. Normally
/// the starter graph; `-mnFixture <name>` on the command line swaps in a deterministic document so
/// the XCUITests can address nodes and sockets by their ids (spec §22.8). `UserDefaults` sees the
/// launch arguments through `NSArgumentDomain`, so no parsing is needed.
enum LaunchFixture {
    static func document() -> ShaderDocument {
        switch UserDefaults.standard.string(forKey: "mnFixture") {
        case "sample": .sample()
        case "textured": .textured()
        default: .starter()
        }
    }
}
```

`MetalNodesApp.swift` — the scene's new document:

```swift
        DocumentGroup(newDocument: ShaderFileDocument(package: ShaderPackage(document: LaunchFixture.document()))) { file in
            DocumentHostView(file: file.$document, device: device, compiler: compiler)
        }
```

- [ ] **Step 5: The XCUITest bundle**

Create `MetalNodesAppUITests/MetalNodesAppUITests.swift`:

```swift
import XCTest

/// The drag-and-drop and gesture checks no unit test can reach (spec §22.8). XCTest, not Swift
/// Testing: XCUITest has no Swift Testing surface. Every test launches with `-mnFixture <name>`, so
/// the document on screen is deterministic and its node ids are known.
@MainActor
final class MetalNodesAppUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Harness

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mnFixture", fixture]
        app.launch()
        #if os(iOS)
        // iPadOS opens the document browser first; Create Document makes the fixture document.
        let create = app.buttons["Create Document"]
        if create.waitForExistence(timeout: 20) { create.tap() }
        #endif
        XCTAssertTrue(app.otherElements["canvas"].waitForExistence(timeout: 30), "the canvas never appeared")
        return app
    }

    /// Identifiers are set on containers whose element type differs by platform (a palette row is a
    /// static text on macOS and a group on iPadOS), so every lookup goes through `descendants`.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func nodeCount(_ app: XCUIApplication) -> Int {
        app.otherElements.matching(NSPredicate(format: "identifier BEGINSWITH 'node.'")).count
    }

    /// Polls, because a SwiftUI update lands a frame or two after the gesture ends.
    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// The inspector's "N nodes selected" line — the only place the selection size is rendered as
    /// text. Shown for two or more nodes, which is exactly what the marquee tests assert.
    private func selectedNodeCount(_ app: XCUIApplication) -> Int {
        let query = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'nodes selected'"))
        guard let label = query.allElementsBoundByIndex.first?.label,
              let n = Int(label.split(separator: " ").first ?? "") else { return 0 }
        return n
    }

    // MARK: Tests

    #if os(macOS)
    /// Palette → canvas drag-in, the check M5 could not automate.
    func testPaletteDragPlacesANode() {
        let app = launch(fixture: "starter")
        let canvas = app.otherElements["canvas"]
        let row = element(app, "palette.input.time")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Time row is not in the palette")
        let before = nodeCount(app)
        row.press(forDuration: 0.5, thenDragTo: canvas)
        XCTAssertTrue(wait { self.nodeCount(app) == before + 1 },
                      "the drag placed \(nodeCount(app) - before) nodes, expected 1")
    }
    #endif

    #if os(iOS)
    /// One tap on a palette row places at the viewport centre (spec §22.3).
    func testTapToPlaceOnIPad() {
        let app = launch(fixture: "starter")
        let row = element(app, "palette.input.time")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Time row is not in the palette")
        let before = nodeCount(app)
        row.tap()
        XCTAssertTrue(wait { self.nodeCount(app) == before + 1 },
                      "the tap placed \(nodeCount(app) - before) nodes, expected 1")
    }

    /// Pinch zooms the canvas: the same node draws wider afterwards.
    func testPinchZooms() {
        let app = launch(fixture: "textured")
        let node = element(app, "node.00000101")
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        let before = node.frame.width
        app.otherElements["canvas"].pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(wait { node.frame.width > before * 1.3 },
                      "the node is \(node.frame.width) pt wide, was \(before) pt")
    }

    /// Lasso mode: a drag across the graph replaces the selection with what it crossed.
    func testLassoSelects() {
        let app = launch(fixture: "sample")
        let lasso = app.buttons["Lasso"]
        XCTAssertTrue(lasso.waitForExistence(timeout: 10), "the canvas-mode picker is missing")
        lasso.tap()
        let canvas = app.otherElements["canvas"]
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.05))
            .press(forDuration: 0.1,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)))
        XCTAssertTrue(wait { self.selectedNodeCount(app) >= 2 },
                      "the lasso selected \(selectedNodeCount(app)) nodes, expected at least 2")
    }
    #endif

    /// Long-press (iPad) / right-click (macOS) opens the canvas menu (spec §22.3).
    func testLongPressOpensTheContextMenu() {
        let app = launch(fixture: "sample")
        let canvas = app.otherElements["canvas"]
        #if os(iOS)
        canvas.press(forDuration: 0.6)
        #else
        canvas.rightClick()
        #endif
        XCTAssertTrue(app.buttons["Add Sticky Note"].waitForExistence(timeout: 5),
                      "the context menu did not appear")
    }

    /// A wire drawn by hand: the fixture's Texture Sample output onto the Fragment Output's body,
    /// which auto-connects to its `color` input. Read back through the inspector, where a connected
    /// input row reads "← <source>".
    func testWireDragConnects() {
        let app = launch(fixture: "textured")
        let out = element(app, "node.00000103")
        let socket = element(app, "socket.00000102.color")
        XCTAssertTrue(out.waitForExistence(timeout: 10), "the Fragment Output is not on the canvas")
        XCTAssertTrue(socket.waitForExistence(timeout: 10), "the Texture Sample's colour socket is not on the canvas")

        let connected = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '← '"))
        out.tap()
        XCTAssertFalse(connected.firstMatch.waitForExistence(timeout: 2),
                       "the Fragment Output already has a connected input")

        socket.press(forDuration: 0.3, thenDragTo: out)
        out.tap()
        XCTAssertTrue(connected.firstMatch.waitForExistence(timeout: 5),
                      "no wire arrived at the Fragment Output")
    }
}
```

- [ ] **Step 6: The pbxproj hunks**

Edit `MetalNodes.xcodeproj/project.pbxproj` **in a text editor only** — opening the project through Xcode or its MCP reorders every key (Global Constraints). Six insertions and three in-place edits, in file order.

(a) A new `PBXContainerItemProxy` section, immediately after `/* End PBXBuildFile section */` and its blank line:

```
/* Begin PBXContainerItemProxy section */
		000000000000000260000000 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = 000000000000000000000000 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = 000000000000000100000000;
			remoteInfo = MetalNodes;
		};
/* End PBXContainerItemProxy section */

```

(b) In `PBXFileReference`, after the `MetalNodes.app` line:

```
		000000000000000000000130 /* MetalNodesAppUITests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = MetalNodesAppUITests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
```

(c) In `PBXFileSystemSynchronizedRootGroup`, after the `MetalNodes` group's closing `};`:

```
		000000000000000000000030 /* MetalNodesAppUITests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = MetalNodesAppUITests;
			sourceTree = "<group>";
		};
```

(d) In `PBXFrameworksBuildPhase`, after the existing phase's closing `};`:

```
		000000000000000230000000 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			files = (
			);
		};
```

(e) In `PBXGroup`: add the folder to the root group's children and the product to Products:

```
		000000000000000000000001 = {
			isa = PBXGroup;
			children = (
				000000000000000000000010 /* MetalNodes */,
				000000000000000000000030 /* MetalNodesAppUITests */,
				000000000000000000000020 /* Products */,
			);
			sourceTree = "<group>";
		};
		000000000000000000000020 /* Products */ = {
			isa = PBXGroup;
			children = (
				000000000000000000000120 /* MetalNodes.app */,
				000000000000000000000130 /* MetalNodesAppUITests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
```

(f) In `PBXNativeTarget`, after the `MetalNodes` target's closing `};` — the app target itself is **unchanged**:

```
		000000000000000200000000 /* MetalNodesAppUITests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = 000000000000000210000000 /* Build configuration list for PBXNativeTarget "MetalNodesAppUITests" */;
			buildPhases = (
				000000000000000220000000 /* Sources */,
				000000000000000230000000 /* Frameworks */,
				000000000000000240000000 /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				000000000000000250000000 /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				000000000000000000000030 /* MetalNodesAppUITests */,
			);
			name = MetalNodesAppUITests;
			productName = MetalNodesAppUITests;
			productReference = 000000000000000000000130 /* MetalNodesAppUITests.xctest */;
			productType = "com.apple.product-type.bundle.ui-testing";
		};
```

(g) In `PBXProject`, `TargetAttributes` gains the test target and `targets` gains its entry:

```
				TargetAttributes = {
					000000000000000100000000 = {
						CreatedOnToolsVersion = 26.3;
					};
					000000000000000200000000 = {
						CreatedOnToolsVersion = 27.0;
						TestTargetID = 000000000000000100000000;
					};
				};
```

```
			targets = (
				000000000000000100000000 /* MetalNodes */,
				000000000000000200000000 /* MetalNodesAppUITests */,
			);
```

(h) In `PBXResourcesBuildPhase` and `PBXSourcesBuildPhase`, after each existing phase's closing `};`:

```
		000000000000000240000000 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			files = (
			);
		};
```

```
		000000000000000220000000 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			files = (
			);
		};
```

(i) A new `PBXTargetDependency` section, immediately after `/* End PBXSourcesBuildPhase section */` and its blank line:

```
/* Begin PBXTargetDependency section */
		000000000000000250000000 /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = 000000000000000100000000 /* MetalNodes */;
			targetProxy = 000000000000000260000000 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

```

(j) In `XCBuildConfiguration`, after the app's Release configuration's closing `};`:

```
		000000000000000211000000 /* Debug configuration for PBXNativeTarget "MetalNodesAppUITests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = VH3VD452Q2;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 27.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = (
					"@executable_path/../Frameworks",
					"@loader_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.maxburger.MetalNodesAppUITests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = 2;
				TEST_TARGET_NAME = MetalNodes;
			};
			name = Debug;
		};
		000000000000000212000000 /* Release configuration for PBXNativeTarget "MetalNodesAppUITests" */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEVELOPMENT_TEAM = VH3VD452Q2;
				GENERATE_INFOPLIST_FILE = YES;
				IPHONEOS_DEPLOYMENT_TARGET = 27.0;
				LD_RUNPATH_SEARCH_PATHS = (
					"@executable_path/Frameworks",
					"@loader_path/Frameworks",
				);
				"LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]" = (
					"@executable_path/../Frameworks",
					"@loader_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 26.0;
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.maxburger.MetalNodesAppUITests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SDKROOT = auto;
				SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";
				SWIFT_EMIT_LOC_STRINGS = NO;
				SWIFT_VERSION = 6.0;
				TARGETED_DEVICE_FAMILY = 2;
				TEST_TARGET_NAME = MetalNodes;
			};
			name = Release;
		};
```

There is deliberately no `BUNDLE_LOADER` and no `TEST_HOST`: a UI-testing bundle launches the app as a separate process, and setting either would try to link against it. `SWIFT_DEFAULT_ACTOR_ISOLATION` is left at the project default (the app target sets it, this one does not), which is why the test class carries an explicit `@MainActor`.

(k) In `XCConfigurationList`, after the app target's list:

```
		000000000000000210000000 /* Build configuration list for PBXNativeTarget "MetalNodesAppUITests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				000000000000000211000000 /* Debug configuration for PBXNativeTarget "MetalNodesAppUITests" */,
				000000000000000212000000 /* Release configuration for PBXNativeTarget "MetalNodesAppUITests" */,
			);
			defaultConfigurationName = Release;
		};
```

- [ ] **Step 7: The shared scheme**

Create `MetalNodes.xcodeproj/xcshareddata/xcschemes/MetalNodes.xcscheme` — the only file under `xcshareddata` that is ever committed:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2700"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000100000000"
               BuildableName = "MetalNodes.app"
               BlueprintName = "MetalNodes"
               ReferencedContainer = "container:MetalNodes.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference
            skipped = "NO">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "000000000000000200000000"
               BuildableName = "MetalNodesAppUITests.xctest"
               BlueprintName = "MetalNodesAppUITests"
               ReferencedContainer = "container:MetalNodes.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "MetalNodes.app"
            BlueprintName = "MetalNodes"
            ReferencedContainer = "container:MetalNodes.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "000000000000000100000000"
            BuildableName = "MetalNodes.app"
            BlueprintName = "MetalNodes"
            ReferencedContainer = "container:MetalNodes.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
```

- [ ] **Step 8: Run the UI tests on both destinations**

Pick a simulator that actually exists on this machine first:

```bash
xcrun simctl list devices available | grep -i ipad
```

then run, substituting the name that came back for `iPad Pro 13-inch (M4)`:

```bash
xcodebuild test -project MetalNodes.xcodeproj -scheme MetalNodes \
  -destination 'platform=macOS' -only-testing:MetalNodesAppUITests
```

```bash
xcodebuild test -project MetalNodes.xcodeproj -scheme MetalNodes \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' -only-testing:MetalNodesAppUITests
```

Expected: `TEST SUCCEEDED` on both — macOS runs `testPaletteDragPlacesANode`, `testLongPressOpensTheContextMenu`, `testWireDragConnects`; the iPad Simulator runs `testTapToPlaceOnIPad`, `testPinchZooms`, `testLassoSelects`, `testLongPressOpensTheContextMenu`, `testWireDragConnects`. Also run the package suite and both `xcodebuild … build` commands from Global Constraints.

- [ ] **Step 9: Commit**

Check the pbxproj diff is only the hunks above — `git diff --stat MetalNodes.xcodeproj/project.pbxproj` should show no deletions beyond the three edited blocks in (e) and (g), and `git status` must show no `xcuserdata/`.

```bash
git add MetalNodesKit MetalNodes MetalNodesAppUITests MetalNodes.xcodeproj
git commit -m "$(cat <<'EOF'
test(app): MetalNodesAppUITests target with palette drag, gesture and fixture launch

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---

### Task 11: Integration — suite, builds, iPad checklist, macOS regression subset

**Files:**
- Modify: `README.md:80-89` (the roadmap table)
- Modify: whatever the checks below turn up, each in its own fix commit

**Interfaces:** none — this task adds no API. It is the milestone's acceptance run.

**Run by the controller with computer-use on the iPad Simulator; subagents cannot obtain screen control** (M4 ruling R18, and the same limitation that left M5's check 5 owed to a human). A subagent may execute Step 1 and Step 4; Steps 2 and 3 are the controller's.

- [ ] **Step 1: Suite, greps, three builds**

Run:

```bash
swift test --package-path MetalNodesKit
swift build --package-path MetalNodesKit 2>&1 | grep -i warning     # prints nothing
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build
```

The third build is the Xcode 26.6 one Xcode Cloud uses (Global Constraints). Then the greps:

```bash
grep -rn '#[0-9a-fA-F]\{6\}' MetalNodesKit/Sources --include=*.swift | grep -v DraculaTheme.swift
grep -rn '^import ' MetalNodesKit/Sources/MetalNodesCore --include=*.swift | grep -v 'Foundation\|CoreGraphics'
grep -rn 'import AppKit' MetalNodesKit/Sources/MetalNodesUI --include=*.swift
grep -rn 'import UIKit\|import PhotosUI' MetalNodesKit/Sources/MetalNodesUI --include=*.swift
git status --porcelain MetalNodes.xcodeproj
```

Expected: the first two empty; every AppKit hit inside a `*Mac.swift` file or an `#if os(macOS)` block; every UIKit/PhotosUI hit inside a `*Pad.swift` file or an `#if os(iOS)` block; `git status` clean for the project (no `xcuserdata/`, no key reorder).

- [ ] **Step 2: iPad Simulator checklist** (controller, computer-use, iPad Pro 13-inch simulator running iPadOS 27, landscape, full screen; record observed/failed per item)

1. **New document.** Launch → the document browser; Create Document → the editor with the palette sidebar, the breadcrumb reading "Shader", the canvas showing UV → Fragment Output, and the inspector column on the right; the preview renders the gradient.
2. **Open Sample Shader.** The document toolbar's ⋯ ▸ Open Sample Shader → the sample opens in its own window and renders the animated noise mix; the original document is still open behind it.
3. **Save and reopen.** Move a node, pan the canvas, tap Documents → the file is listed as `Untitled.mnshader`; reopen it → the moved node, the pan and the zoom are exactly as they were left.
4. **Tap (pointer mode).** Tap a node → accent outline and the node's pane in the inspector; tap a wire → the wire highlights; tap the ◉ badge on a node header → the preview switches to that socket and the badge lights; tap empty canvas → everything deselects (the badge stays lit — the viewer is not a selection).
5. **One-finger drag on a node.** Drag an unselected node → it selects and moves with the finger, its wires following; lift → one "Undo Move" step; the toolbar's Undo restores the old position. A drag shorter than ~6 pt moves nothing.
6. **One-finger wire drag.** Drag from an output socket onto another node's body → the wire connects to the best-matching input; drag from an output onto empty canvas → the chooser opens at the release point listing only compatible rows; tap outside → no wire and no undo step left behind.
7. **Panning.** One-finger drag on empty canvas in pointer mode → the canvas pans and stops dead when the finger lifts (no inertia); two-finger drag pans in pointer, select **and** lasso mode.
8. **Pinch.** Two-finger pinch → the canvas zooms about the point between the fingers, not the viewport centre; zoom far out → nodes drop to their LOD drawing; zoom back in → detail returns.
9. **Select mode.** Tap the middle segment; drag on empty canvas → a marquee that **adds** its catch to the existing selection; tap a selected node → it leaves the selection; tap empty canvas → the selection is kept.
10. **Lasso mode.** Tap the right segment; drag across three nodes → exactly those three are selected, replacing what was selected before; the inspector reads "3 nodes selected".
11. **Double-tap chooser.** Double-tap empty canvas → the chooser appears at that point with the field focused and the software keyboard up; type "mix", Return → a Mix node lands where the double-tap was.
12. **Toolbar ✛, fit, minimap.** ✛ → the chooser at the viewport centre; with nothing selected Zoom to Fit frames the whole graph; with two nodes selected it frames just those; the minimap sits bottom-trailing, a tap on its far right recentres the viewport, and View ▸ Minimap off then reopening the document keeps it off.
13. **Long-press menu.** Long-press a group instance → the menu with Cut/Copy/Paste/Duplicate/Delete, Group/Ungroup/Make Unique/Edit Group/Exit Group, Frame Selection/Add Sticky Note, and Set Viewer; Ungroup and Edit Group are enabled, Paste is disabled with an empty clipboard. Copy a node, long-press empty canvas → Paste lands the copy at the press point; Add Sticky Note centres a note there. Long-press moving more than ~6 pt opens nothing.
14. **Hardware keyboard.** With a keyboard attached: ⌘Z / ⇧⌘Z step the same history the toolbar does; ⌘C then ⌘V pastes at the viewport centre; ⌘A selects every node and comment; ⌫ deletes the selection; arrows nudge 1 pt and ⇧-arrows 10 pt; ⇧A opens the chooser; Escape cancels a chooser and clears the selection. With a node's parameter field focused, ⌫ edits the text and does not delete the node.
15. **Inspector edits.** Rename a node's title, scrub a slider, change an enum popup → the canvas and the preview follow, and the slider does not recompile while the enum does; the toolbar's inspector button hides and shows the column, and the state survives closing and reopening the document.
16. **Image import.** Place a Texture Sample → the placeholder renders; "Photos…" → pick an image → thumbnail in the well and the image in the preview, upright; "Files…" → pick a PNG from On My iPad → same; cancelling either picker leaves the node unchanged. Delete the file from the package in Files, reopen → the missing-texture warning, then relink through "Files…" clears it.
17. **Export.** Export ▸ Export to Files… → save to On My iPad → the folder holds the `.metal` (and, for a stitchable target, the `.swift`); Export ▸ Share… → the share sheet with the same files → Save to Files writes them. With an invalid graph, Export to Files… raises the "The graph has errors" alert and writes nothing.
18. **Code panel.** View ▸ Generated Code (⌘⌥C) → the panel appears under the preview inside the inspector column at a fixed height, the source is Dracula-highlighted, and selecting a single node highlights its lines; Copy puts the source on the clipboard.
19. **Compact width.** Drag another app in as Slide Over, or narrow the Split View → "MetalNodes needs a wider window" and no canvas; widen again → the canvas, the selection and the camera come back unchanged and nothing was lost.
20. **Layer Effect export of a grouped sample.** Open the sample, group the Time → Multiply → Sine chain, add a Texture Sample inside the definition, set the target to Layer Effect → no validation error, the preview renders; export and confirm the `.metal` contains a `…_layer(` function and `float4(layer.sample(position))` and no `texture2d` parameter, and that it compiles with `xcrun metal -c` on the Mac.

- [ ] **Step 3: macOS regression subset** (same machine, Xcode-built Debug app; these are copied verbatim from the M5 and M4 plans so a failure is comparable to the original observation)

M5 checklist:
1. File ▸ New → UV → Output window; title "Untitled"; edit → dirty dot; ⌘S → `Test.mnshader`; Finder shows a single file; `document.json`/`view.json`/`textures/` inside.
2. Close, reopen from Finder → graph, camera and selection restored; Edit ▸ Undo titles come from the window ("Undo Move").
3. Help ▸ Open Sample Shader → the demo in a new window.
4. Palette ▸ Texture Sample → node with an empty image well; preview shows the magenta/black placeholder through the node; "Choose…" → pick a PNG → thumbnail, preview shows the image, upright (uv.y=0 at the bottom).
5. Drop a JPEG from Finder onto the canvas → Texture Sample at the drop point with the image; ⌘Z removes node and manifest entry. *(Still the hand-only check: XCUITest cannot drive a cross-application drag.)*
12. Copy a Texture Sample, paste into a new document → image comes along (thumbnail + render); paste again → no duplicate asset.
17. View ▸ Generated Code → pane; select a node → its lines highlighted; select a node inside a definition → its lines in the group function highlighted; Copy → clipboard has the source; a broken graph still updates the panel.

M4 checklist:
8. Rename `b` → `phase` in the definition pane: the instance's socket reads `phase`, wires intact; remove `time`: the wire into the instance disappears; one ⌘Z brings socket + wire back.
17. Stitchable target with a grouped graph: preview renders for all three kinds; Export writes both files; snippet argument names include the instance's unwired input (`groupPhase`…).

Additionally confirm the right-click canvas menu added in Task 8 opens on macOS and its items behave as their Edit-menu twins (the one behaviour this subset does not inherit from M4/M5).

- [ ] **Step 4: Fixes, README, close the milestone**

Every defect from Steps 2–3 is its own commit named for the check that found it:

```bash
git commit -m "$(cat <<'EOF'
fix(ui): <what was wrong, in one line> — manual check 13

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

(`fix(ui|core|render|app)` per the area, `— manual check N` naming the iPad item, or `— macOS regression M5-5` for a subset item.) After each fix re-run the package suite and both builds; re-run the failed check before moving on.

Then the roadmap in `README.md` — replace the last two rows of the table with:

```markdown
| M6 iPadOS UI layer — touch canvas, iPad layout, Photos/Files import, Files/Share export, hardware keyboard, XCUITests | done |
| M7 — to be brainstormed | planned |
```

```bash
git add README.md
git commit -m "$(cat <<'EOF'
docs(readme): M6 done, M7 planned

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
EOF
)"
```

---
