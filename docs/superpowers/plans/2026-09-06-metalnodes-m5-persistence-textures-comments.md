# MetalNodes M5 — Persistence, Textures, Comments, Code Panel, Minimap — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shaders become real documents (`.mnshader` packages with textures), the library gains Texture Sample plus Gradient and Checker, the fragment target exports `.metal`, the canvas gains comment frames, sticky notes, a generated-code panel, a minimap and ⇧A access to definitions, and the M4 carry-overs (shape cache, line owners in group functions, dead code) are closed.

**Architecture:** A Foundation-only `ShaderPackage` value is the package on disk; the app's `DocumentGroup` wraps it in a `FileDocument` and a per-window host owns the `EditorModel`, mirroring changes back and injecting the window's `UndoManager`. Textures are assets in the document manifest with bytes beside the JSON; codegen allocates one `texture2d` slot per asset (group functions take them as parameters like uniforms) and the renderer binds them from a `TextureStore`. Comments are graph metadata with their own `DocumentChange` cases and geometry-based frame membership. The code panel and minimap are read-only views over state the model already has (`generatedSource` + `lineMap`, the active graph + shapes).

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 / iPadOS 27), Metal / MetalKit, Swift Testing, SwiftPM package `MetalNodesKit`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §3, §6, §7.1, §9.1, §9.5, §11.4–11.6, §13, and **§21 (M5 addendum)**, which pins the mechanics. Read §21 in full before any task.

## Global Constraints

- Swift language mode `6`, strict concurrency, warning-free build (`swift build --package-path MetalNodesKit 2>&1 | grep -i warning` prints nothing).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics` (`FileWrapper` is Foundation). `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore`. `MetalNodesUI` may import AppKit only under `#if os(macOS)` in `*Mac.swift` files or gated sections; UniformTypeIdentifiers is allowed in UI and the app.
- `MetalNodesUI` and `MetalNodesUITests` have `.defaultIsolation(MainActor.self)`; Core and Render do not.
- Colors only through `DraculaTheme` / `DraculaToken`; no hex outside `DraculaTheme.swift`. Red = errors only.
- Every document edit goes through `EditorModel.apply(_:)` on the active graph path; views never mutate `document`. Undo = whole-document snapshots in transactions; view state (`EditorViewState`) is never snapshotted or undone. Comments are document data (undoable); their selection is view state.
- Package format: `document.json`, `view.json`, `textures/<uuid>.<ext>`; JSON with `.sortedKeys` + `.prettyPrinted`; `formatVersion` 1; a newer version is refused with "This shader was saved by a newer version of MetalNodes"; textures bytes are never re-encoded; assets are never auto-pruned.
- Texture slots: one per distinct `AssetID` in first-use order, plus one shared `nil` slot for unassigned samples; fragment binds `texture2d<float> tex<i> [[texture(i)]]`; group functions take `texture2d<float>` parameters named `t_<8hex assetid>` (or `t_none`); Color/Distortion Effect refuse Texture Sample with "Texture Sample needs the Layer Effect target"; Layer Effect export uses `layer.sample(position)`.
- Documents without textures, comments or groups must generate byte-identical MSL to M4 (existing goldens unchanged).
- Node width stays `190`; `.dot` 24 × 24; culling/LOD unchanged.
- Tests: Swift Testing only; goldens compared whole; under `#expect` compare against single typed literals. Package suite: `swift test --package-path MetalNodesKit`. App build: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- `MetalNodes.xcodeproj/project.pbxproj` may change only where a task says so (Info.plist keys for the document type); never commit key reorders beyond that or `xcshareddata/`.

---

## File structure

**Core (`MetalNodesKit/Sources/MetalNodesCore`)**
- Modify `ShaderDocument.swift` — `AssetInfo`, `DocumentSettings.assets` (T1). Modify `NodeDef.swift` — `EmitContext.texture` (T1). Create `Library/Builtin/TextureNodes.swift` (T1). Modify `Codegen/Emitter.swift`, `Codegen/EmitEnvironment.swift`, `Codegen/GroupCodegen.swift`, `Codegen/ShaderGenerator.swift`, `Codegen/ShaderGenerator+Viewer.swift`, `Codegen/StitchableCodegen.swift`, `Codegen/Validation.swift` — texture slots (T1). Create `Codegen/TextureSlot.swift` (T1).
- Create `Persistence/ShaderPackage.swift` — package read/write (T3).
- Modify `Export/ShaderExport.swift` — fragment `.metal` export (T5).
- Modify `Clipboard/GraphClipboard.swift` — `textures` (T7).
- Modify `Codegen/LineMap.swift`, `GroupCodegen.swift`, `ShaderGenerator.swift` — group-function owners; delete `diagnostics(_:)` (T10).
- Create `Library/StarterDocuments.swift` — `ShaderDocument.starter()` (T4).

**Render** — Create `TextureStore.swift` (T2). Modify `PreviewState.swift`, `ShaderRenderer.swift` (T2).

**App (`MetalNodes/`)** — Modify `MetalNodesApp.swift`; create `ShaderFileDocument.swift`, `DocumentHostView.swift`; Info.plist document/exported type entries (T4).

**UI (`MetalNodesKit/Sources/MetalNodesUI`)**
- Modify `Editor/EditorModel.swift` (`textures`, `undoManager` injection, `missingAssets` diagnostics, `shapes` cache), `EditorModel+Undo.swift` (T4, T14). Create `Editor/EditorModel+Assets.swift` (T6). Create `Editor/ImagePanelMac.swift` (T6). Modify `Canvas/ParamControl.swift`, `Editor/InspectorView.swift`, `Canvas/GraphCanvasView.swift` (drop) (T6).
- Modify `Editor/DocumentChange.swift`; create `Editor/EditorModel+Comments.swift` (T8). Create `Canvas/CommentLayer.swift`, `Canvas/StickyView.swift`, `Canvas/FrameView.swift`; modify `Canvas/GraphCanvasView.swift`, `Editor/EditorCommands.swift`; create `Editor/InspectorView+Comments.swift` (T9).
- Create `Editor/CodePanel.swift`, `Editor/MSLHighlighter.swift`; modify `Editor/EditorView.swift`, `Editor/EditorCommands.swift` (T11).
- Create `Canvas/MinimapLayout.swift`, `Canvas/MinimapView.swift`; modify `Canvas/GraphCanvasView.swift`, `Editor/EditorCommands.swift` (T12).
- Modify `Palette/NodeSearchPopover.swift`, `Palette/PaletteSearch.swift`, `Canvas/GraphCanvasView.swift` (T13).
- Modify `Canvas/NodeGeometry.swift`, `Canvas/DropResolver.swift`, `Editor/EditorModel.swift` (T14).

**Tests** — Core: `TextureCodegenTests`, `ShaderPackageTests`, `FragmentExportTests`, `ClipboardTexturesTests`, `LineMapGroupTests`; Render: `TextureStoreTests`, additions to `ShaderCompilerTests`; UI: `EditorUndoInjectionTests`, `EditorAssetsTests`, `EditorCommentsTests`, `MSLHighlighterTests`, `MinimapLayoutTests`, `NodeSearchRowsTests`, `ShapeCacheTests`, updates to `NodeGeometryTests` / `DropResolverTests`; App: none (the host is exercised by hand in T15).

---

### Task 1: Texture nodes and texture slots in codegen

**Files:**
- Create: `Library/Builtin/TextureNodes.swift`, `Codegen/TextureSlot.swift`
- Modify: `ShaderDocument.swift`, `NodeDef.swift`, `Library/BuiltinNodes.swift`, `Codegen/Emitter.swift`, `Codegen/EmitEnvironment.swift`, `Codegen/GroupCodegen.swift`, `Codegen/ShaderGenerator.swift`, `Codegen/ShaderGenerator+Viewer.swift`, `Codegen/StitchableCodegen.swift`, `Codegen/Validation.swift`, `Library/MSLStdlib.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TextureCodegenTests.swift`, `LibraryM3Tests.swift` (node count 43)

**Interfaces:**
- Produces: `AssetInfo(name:pixelSize:fileExtension:)`; `DocumentSettings.assets: [AssetID: AssetInfo]` (Codable, default empty, tolerant); `TextureSlot { index: Int, asset: AssetID? }` (Sendable, Hashable, Codable); `GeneratedShader.textures: [TextureSlot]` (default `[]`); `EmitContext.texture: String` (the slot expression for this node, empty for non-texture nodes); `EmitEnvironment.texture: @Sendable (TextureSlot) -> String`; `Emitter.Output.textureRequests: [TextureSlot]`; `GroupFunction.textureParams: [TextureSlot]`; builtins `texture.sample`, `texture.gradient`, `texture.checker`; placeholder `{tex}` in node bodies; validation "Texture Sample needs the Layer Effect target"; `MSLStdlib` entry `mn_sampler` (a `constexpr sampler` declaration).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct TextureCodegenTests {
    let reg = NodeRegistry.builtin
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    /// UV → Texture Sample(asset A) → Output; a second Texture Sample of the same asset feeds nothing.
    private func doc() -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.assets[aid(1)] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let uv = NodeInstance(id: id(1), kind: .builtin("input.uv"))
        let s1 = NodeInstance(id: id(2), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let s2 = NodeInstance(id: id(3), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let mix = NodeInstance(id: id(4), kind: .builtin("color.mixColor"), params: ["mode": .enumCase("mix")])
        let out = NodeInstance(id: id(5), kind: .builtin("output.fragment"))
        for n in [uv, s1, s2, mix, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s1.id, "uv"))
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s2.id, "uv"))
        d.root.connect(SocketRef(s1.id, "color"), to: SocketRef(mix.id, "a"))
        d.root.connect(SocketRef(s2.id, "color"), to: SocketRef(mix.id, "b"))
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        return d
    }

    @Test func fragmentBindsOneSlotPerAsset() throws {
        let s = try ShaderGenerator.generate(doc(), registry: reg)
        #expect(s.textures == [TextureSlot(index: 0, asset: aid(1))])
        #expect(s.source.contains("constant Uniforms &u [[buffer(0)]],\n                           texture2d<float> tex0 [[texture(0)]]) {"))
        #expect(s.source.contains("tex0.sample(mn_sampler, "))
        #expect(s.source.components(separatedBy: "tex0.sample(").count == 3)   // two samples, one slot
        #expect(s.source.contains("constexpr sampler mn_sampler(filter::linear, address::repeat);"))
    }

    @Test func unassignedSampleUsesTheNilSlot() throws {
        var d = doc()
        d.root.nodes[id(3)]!.params["asset"] = .asset(nil)
        let s = try ShaderGenerator.generate(d, registry: reg)
        #expect(s.textures == [TextureSlot(index: 0, asset: aid(1)), TextureSlot(index: 1, asset: nil)])
        #expect(s.source.contains("texture2d<float> tex1 [[texture(1)]]"))
    }

    @Test func documentsWithoutTexturesAreUnchanged() throws {
        let s = try ShaderGenerator.generate(.sample(), registry: reg)
        #expect(s.textures.isEmpty)
        #expect(!s.source.contains("texture2d"))
        #expect(!s.source.contains("mn_sampler"))
    }

    @Test func groupFunctionsTakeTextureParameters() throws {
        var def = GroupDefinition.make(name: "Tex")
        def.outputs = [SocketDecl(name: "color", type: .concrete(.color))]
        let s = NodeInstance(kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        def.graph.nodes[s.id] = s
        def.graph.connect(SocketRef(s.id, "color"), to: SocketRef(def.outputNode!, "color"))
        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[inst.id] = inst; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(inst.id, "color"), to: SocketRef(out.id, "color"))
        let g = try ShaderGenerator.generate(d, registry: reg)
        #expect(g.textures == [TextureSlot(index: 0, asset: aid(2))])
        #expect(g.source.contains("(float2 uv, float time, float2 size, float2 mouse, texture2d<float> t_20000000)"))
        #expect(g.source.contains("mn_g_Tex_"))
        #expect(g.source.contains(", tex0);"))                     // the call passes the slot
        #expect(g.source.contains("t_20000000.sample(mn_sampler, "))
    }

    @Test func colorEffectRefusesTextureSampleAndLayerEffectSamplesTheLayer() throws {
        var d = doc()
        d.settings.target = .stitchable(.colorEffect)
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(d, target: d.settings.target, registry: reg) }
        let diags = GraphValidator.validate(document: d, registry: reg, target: .stitchable(.colorEffect))
        #expect(diags.contains { $0.message == "Texture Sample needs the Layer Effect target" && $0.node == id(2) })
        d.settings.target = .stitchable(.layerEffect); d.settings.exportName = "fx"
        let s = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
        #expect(s.exportSource!.contains("layer.sample(position)"))
        #expect(!s.exportSource!.contains("texture2d"))
        #expect(s.source.contains("tex0.sample(mn_sampler, "))     // the preview samples the asset
    }

    @Test func gradientAndCheckerAreOrdinaryColorNodes() throws {
        var d = ShaderDocument()
        let g = NodeInstance(kind: .builtin("texture.gradient")), c = NodeInstance(kind: .builtin("texture.checker"))
        let mix = NodeInstance(kind: .builtin("color.mixColor")), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [g, c, mix, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(g.id, "color"), to: SocketRef(mix.id, "a"))
        d.root.connect(SocketRef(c.id, "color"), to: SocketRef(mix.id, "b"))
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d, registry: reg)
        #expect(s.textures.isEmpty)
        #expect(s.source.contains("mn_checker(") && s.source.contains("mn_gradient("))
        #expect(s.layout.fields.compactMap(\.path).count == 6)    // angle, colorA, colorB, scale, colorA, colorB
    }

    @Test func manifestRoundTripsAndIsTolerant() throws {
        var s = DocumentSettings()
        s.assets[aid(1)] = AssetInfo(name: "x.jpg", pixelSize: CGSize(width: 10, height: 20), fileExtension: "jpg")
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: data) == s)
        let legacy = #"{"previewSize":[512,512],"timeMode":"wallClock","fastMath":true,"target":{"fragment":{}},"exportName":"x"}"#
        let d = try? JSONDecoder().decode(DocumentSettings.self, from: Data(legacy.utf8))
        #expect(d?.assets.isEmpty == true)
    }
}
```

(The `legacy` fixture's `target` encoding is a guess — encode a default `DocumentSettings` once and paste the real JSON minus `assets`; never loosen the decoder.)

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`ShaderDocument.swift`:

```swift
public struct AssetInfo: Sendable, Hashable, Codable {
    public var name: String
    public var pixelSize: CGSize
    public var fileExtension: String
    public init(name: String, pixelSize: CGSize, fileExtension: String) {
        self.name = name; self.pixelSize = pixelSize; self.fileExtension = fileExtension
    }
}
```
`DocumentSettings` gains `public var assets: [AssetID: AssetInfo] = [:]`, key `assets`, `decodeIfPresent … ?? [:]`, encoded as `[AssetID: AssetInfo]` (JSON object keyed by uuid string — check how `[GraphPath: Camera]` encodes; if a dictionary with a struct key encodes as an array, encode `assets` as `[AssetEntry { id, info }]` sorted by id instead, and decode both shapes).

`Codegen/TextureSlot.swift`:

```swift
public struct TextureSlot: Sendable, Hashable, Codable {
    public let index: Int
    public let asset: AssetID?
    public init(index: Int, asset: AssetID?) { self.index = index; self.asset = asset }
    /// `tex0` in the fragment program; `t_<8hex>` / `t_none` as a group-function parameter.
    public var fragmentName: String { "tex\(index)" }
    public var parameterName: String { asset.map { "t_" + String($0.raw.uuidString.prefix(8)).lowercased() } ?? "t_none" }
}
```

`Library/Builtin/TextureNodes.swift`:

```swift
extension BuiltinNodes {
    static let texture: [NodeDef] = [
        NodeDef(id: "texture.sample", title: "Texture Sample", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color)),
                          SocketDecl(name: "alpha", type: .concrete(.float))],
                params: [ParamDecl(name: "asset", label: "Image", kind: .asset, defaultValue: .asset(nil), showsInBody: false)],
                requires: ["mn_sampler"],
                body: .template("""
                float4 {out.color}_s = {tex.sample};
                {out.color} = {out.color}_s;
                {out.alpha} = {out.color}_s.w;
                """)),
        NodeDef(id: "texture.gradient", title: "Gradient", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                params: [ParamDecl(name: "shape", kind: .enumeration(["linear", "radial"]), defaultValue: .enumCase("linear")),
                         ParamDecl(name: "angle", kind: .value(.float, range: 0...360), defaultValue: .float(0)),
                         ParamDecl(name: "colorA", label: "Color A", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(0, 0, 0, 1)), showsInBody: false),
                         ParamDecl(name: "colorB", label: "Color B", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)), showsInBody: false)],
                requires: ["mn_gradient"],
                body: .variants(param: "shape", [
                    "linear": "{out.color} = mix({param.colorA}, {param.colorB}, mn_gradient({in.uv}, {param.angle}));",
                    "radial": "{out.color} = mix({param.colorA}, {param.colorB}, saturate(length({in.uv} - 0.5) * 2.0));",
                ])),
        NodeDef(id: "texture.checker", title: "Checker", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                params: [ParamDecl(name: "scale", kind: .value(.float, range: 1...64), defaultValue: .float(8)),
                         ParamDecl(name: "colorA", label: "Color A", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(0, 0, 0, 1)), showsInBody: false),
                         ParamDecl(name: "colorB", label: "Color B", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)), showsInBody: false)],
                requires: ["mn_checker"],
                body: .template("{out.color} = mix({param.colorA}, {param.colorB}, mn_checker({in.uv}, {param.scale}));")),
    ]
}
```

The Texture Sample body declares a temporary named after the output var (`v3_s`) — `{out.color}` substitutes to the SSA variable name, so `{out.color}_s` is a legal distinct identifier. `{tex.sample}` substitutes to the **complete sample expression** for the target: fragment `tex0.sample(mn_sampler, float2(<uv>.x, 1.0 - <uv>.y))`, group function `t_<hex>.sample(mn_sampler, float2(<uv>.x, 1.0 - <uv>.y))`, Layer Effect export `layer.sample(position)`. The y flip lives in the sample call (not in the loader), so `uv.y = 0` is the bottom (§9.1). `BuiltinNodes.all` gains `+ texture` (before `output`); `LibraryM3Tests.registryHasTheFullV1Set` expects 43.

`MSLStdlib.swift` gains three entries: `mn_sampler` — `constexpr sampler mn_sampler(filter::linear, address::repeat);` (a declaration, emitted like a function, no dependencies); `mn_gradient(float2 uv, float angleDeg)` — projects `uv - 0.5` onto `(cos, sin)` of the angle and maps to 0…1; `mn_checker(float2 uv, float scale)` — `fmod(floor(uv.x*scale) + floor(uv.y*scale), 2.0)`.

`NodeDef.swift`: `EmitContext` gains `public var texture: String = ""` (the substituted sample expression; add it to the init with a default). `Emitter.substitute` gains `case "tex": return ctx.texture` (the existing `{kind.name}` pattern matches `{tex.sample}`).

`EmitEnvironment.swift`: add two closures with defaults so existing call sites compile — `public var textureSample: @Sendable (TextureSlot, _ uvExpr: String) -> String` and `public var textureName: @Sendable (TextureSlot) -> String` (the spelling passed at a group call site). `.fragment`: `"\(slot.fragmentName).sample(mn_sampler, float2(\(uv).x, 1.0 - \(uv).y))"` / `slot.fragmentName`; `.groupFunction`: the same with `slot.parameterName`; `.stitchableFunction` (preview path): like `.fragment`; new `.layerExport`: `{ _, _ in "layer.sample(position)" }` / unused.

`Emitter.swift`: pass 1 collects `textureRequests` — for every builtin node whose body references `{tex.sample}` (detect via `referencedNames` gaining a `usesTexture` flag), the slot is `params["asset"]`'s `AssetID?`; dedupe by asset, first-use order, nil last is *not* required (first-use order overall); for `.group` nodes, propagate `functions[gid].textureParams` like uniform propagation. `Output.textureRequests: [TextureSlot]` is indexed 0… in that order. Pass 2 builds `EmitContext.texture` with `env.textureSample(slot, uvExpr)` where `uvExpr` is the node's resolved `in.uv` expression; group call sites append `env.textureName(slot)` (`tex0` / `t_<hex>`) after the uniform arguments.

`GroupCodegen.function`: parameters gain `texture2d<float> <parameterName>` for each `textureParams` entry after the uniform params; `GroupFunction.textureParams`. Slot indices inside functions are irrelevant (parameters are by name) — `TextureSlot.index` for propagated requests is assigned by the *root* emitter when it dedupes.

`ShaderGenerator`: `GeneratedShader.textures` = root emitter's deduped requests. `assembleFragment` signature line becomes multi-line with one `texture2d<float> tex<i> [[texture(i)]]` per slot (comma-separated, each on its own line indented to match the existing `constant Uniforms` line) — only when non-empty so untextured output is byte-identical. Viewer programs (`+Viewer.swift`) do the same. `assembleStitchable`: preview program binds textures like the fragment program; the export function under `.layerEffect` uses `EmitEnvironment.layerExport` (no texture parameters; `layer.sample(position)` in the body); under `.colorEffect`/`.distortionEffect` validation already threw.

`Validation.swift`: in the per-node loop, `case .builtin("texture.sample") where target is .stitchable(.colorEffect) or .stitchable(.distortionEffect)` → `Diagnostic(.error, "Texture Sample needs the Layer Effect target", node: n.id)`.

`StitchableCodegen`: nothing else — `Argument`s exclude textures because `.texture` is not uniformable.

- [ ] **Step 4: Run** the suite; all pre-existing goldens must be byte-identical.

- [ ] **Step 5: Commit** — `feat(core): Texture Sample, Gradient, Checker; texture slots through fragment, group and stitchable codegen`

---

### Task 2: Texture binding in the renderer

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/TextureStore.swift`
- Modify: `PreviewState.swift`, `ShaderRenderer.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/TextureStoreTests.swift`, `ShaderCompilerTests.swift`

**Interfaces:**
- Produces: `TextureStore(device:)` with `func texture(for asset: AssetID?, bytes: Data?) -> MTLTexture` (cached by asset; `nil` asset or `nil`/undecodable bytes → the placeholder), `placeholder: MTLTexture` (2×2 magenta/black), `func evict(_ asset: AssetID)`, `func bindings(for slots: [TextureSlot], textures: [AssetID: Data]) -> [Int: MTLTexture]`; `PreviewState.textures: [Int: MTLTexture]`; the renderer calls `enc.setFragmentTexture(tex, index: i)` for every entry.

- [ ] **Step 1: Tests** — `TextureStoreTests`: placeholder is 2×2 and returned for a `nil` asset and for garbage bytes; a 4×4 PNG (build it with `CGImage` + `CGImageDestination` in the test, or a hard-coded PNG byte literal) decodes to a 4×4 texture and is cached (same object on the second call); `bindings(for:textures:)` maps slot indices. `ShaderCompilerTests`: compile `TextureCodegenTests.doc()`-shaped documents (fragment, viewer, layer-effect preview) — build them in the Render test target — and draw one frame offscreen? Keep to compile only (the renderer draws on an `MTKView`); compile success is the gate.

- [ ] **Step 2: Implement** — `TextureStore` is `@MainActor final class` (the renderer runs on the main thread); loads with `MTKTextureLoader(device:).newTexture(data:options: [.SRGB: false, .origin: MTKTextureLoader.Origin.topLeft])`; the placeholder is made with `device.makeTexture(descriptor:)` + `replace(region:…)`. `ShaderRenderer.draw` binds `state.textures` after the fragment buffer. `EditorModel.compileNow` (T4/T6 wire `textures` into the model) sets `preview.textures = store.bindings(for: pipeline.shader.textures, textures: textures)` whenever a pipeline lands or the manifest/bytes change.

- [ ] **Step 3: Commit** — `feat(render): TextureStore with placeholder; renderer binds texture slots`

---

### Task 3: `ShaderPackage` — the `.mnshader` package on disk

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Persistence/ShaderPackage.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ShaderPackageTests.swift`

**Interfaces:**
- Produces: `ShaderPackage { document: ShaderDocument, viewState: EditorViewState, textures: [AssetID: Data], missingTextures: Set<AssetID> }`; `init(document:viewState:textures:)`; `init(fileWrapper:) throws(PackageError)`; `func fileWrapper() throws -> FileWrapper`; `PackageError { case notAPackage, missingDocument, undecodable(String), newerFormat(Int) }` with `LocalizedError` descriptions (newer: "This shader was saved by a newer version of MetalNodes"); `ShaderPackage.documentFileName = "document.json"`, `viewFileName = "view.json"`, `texturesDirectory = "textures"`; `static func fileName(for asset: AssetID, info: AssetInfo) -> String` (`<uuid lowercased>.<ext>`).

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ShaderPackageTests {
    private func png() -> Data { Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]) }   // bytes are opaque to the package

    @Test func roundTripsDocumentViewAndTextures() throws {
        var doc = ShaderDocument.sample()
        let a = AssetID()
        doc.settings.assets[a] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 4, height: 4), fileExtension: "png")
        var view = EditorViewState(); view.cameras[.root] = Camera(pan: CGSize(width: 3, height: 4), zoom: 2)
        let pkg = ShaderPackage(document: doc, viewState: view, textures: [a: png()])
        let wrapper = try pkg.fileWrapper()
        #expect(wrapper.isDirectory)
        #expect(Set(wrapper.fileWrappers!.keys) == ["document.json", "view.json", "textures"])
        #expect(wrapper.fileWrappers!["textures"]!.fileWrappers!.keys.contains("\(a.raw.uuidString.lowercased()).png"))
        let back = try ShaderPackage(fileWrapper: wrapper)
        #expect(back.document == doc)
        #expect(back.viewState == view)
        #expect(back.textures == [a: png()])
        #expect(back.missingTextures.isEmpty)
    }

    @Test func jsonIsSortedAndIndented() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        let text = String(decoding: wrapper.fileWrappers!["document.json"]!.regularFileContents!, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"definitions\""))
    }

    @Test func missingViewAndTexturesAreTolerated() throws {
        var doc = ShaderDocument.sample()
        let a = AssetID()
        doc.settings.assets[a] = AssetInfo(name: "gone.png", pixelSize: .zero, fileExtension: "png")
        let wrapper = try ShaderPackage(document: doc, viewState: EditorViewState(), textures: [:]).fileWrapper()
        wrapper.removeFileWrapper(wrapper.fileWrappers!["view.json"]!)
        let back = try ShaderPackage(fileWrapper: wrapper)
        #expect(back.viewState == EditorViewState())
        #expect(back.missingTextures == [a])
    }

    @Test func unreadableViewFallsBackButUnreadableDocumentFails() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        wrapper.removeFileWrapper(wrapper.fileWrappers!["view.json"]!)
        wrapper.addRegularFile(withContents: Data("nope".utf8), preferredFilename: "view.json")
        #expect(try ShaderPackage(fileWrapper: wrapper).viewState == EditorViewState())
        wrapper.removeFileWrapper(wrapper.fileWrappers!["document.json"]!)
        wrapper.addRegularFile(withContents: Data("nope".utf8), preferredFilename: "document.json")
        #expect(throws: PackageError.self) { try ShaderPackage(fileWrapper: wrapper) }
    }

    @Test func newerFormatIsRefused() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [:]).fileWrapper()
        var text = String(decoding: wrapper.fileWrappers!["document.json"]!.regularFileContents!, as: UTF8.self)
        text = text.replacingOccurrences(of: "\"formatVersion\" : 1", with: "\"formatVersion\" : 99")
            .replacingOccurrences(of: "\"formatVersion\": 1", with: "\"formatVersion\": 99")
        wrapper.removeFileWrapper(wrapper.fileWrappers!["document.json"]!)
        wrapper.addRegularFile(withContents: Data(text.utf8), preferredFilename: "document.json")
        #expect(throws: PackageError.newerFormat(99)) { try ShaderPackage(fileWrapper: wrapper) }
    }

    @Test func strayFilesAreIgnoredAndUnmanifestedTexturesDropped() throws {
        let wrapper = try ShaderPackage(document: .sample(), viewState: EditorViewState(), textures: [AssetID(): png()]).fileWrapper()
        #expect(wrapper.fileWrappers!["textures"]!.fileWrappers!.isEmpty)      // not in the manifest → not written
        wrapper.addRegularFile(withContents: Data(), preferredFilename: ".DS_Store")
        #expect(try ShaderPackage(fileWrapper: wrapper).document == .sample())
    }
}
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

```swift
import Foundation

public enum PackageError: Error, Equatable, LocalizedError {
    case notAPackage, missingDocument, undecodable(String), newerFormat(Int)
    public var errorDescription: String? {
        switch self {
        case .notAPackage: "This is not a MetalNodes shader package."
        case .missingDocument: "The package has no document.json."
        case .undecodable(let why): "The shader could not be read: \(why)"
        case .newerFormat: "This shader was saved by a newer version of MetalNodes"
        }
    }
}

public struct ShaderPackage: Sendable, Equatable {
    public static let documentFileName = "document.json"
    public static let viewFileName = "view.json"
    public static let texturesDirectory = "textures"

    public var document: ShaderDocument
    public var viewState: EditorViewState
    public var textures: [AssetID: Data]
    public private(set) var missingTextures: Set<AssetID> = []

    public init(document: ShaderDocument, viewState: EditorViewState = EditorViewState(), textures: [AssetID: Data] = [:]) {
        self.document = document; self.viewState = viewState; self.textures = textures
    }

    public static func fileName(for asset: AssetID, info: AssetInfo) -> String {
        "\(asset.raw.uuidString.lowercased()).\(info.fileExtension)"
    }

    static var encoder: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys, .prettyPrinted]; return e }

    public init(fileWrapper w: FileWrapper) throws(PackageError) {
        guard w.isDirectory, let files = w.fileWrappers else { throw .notAPackage }
        guard let docData = files[Self.documentFileName]?.regularFileContents else { throw .missingDocument }
        // Version gate before full decoding, so a newer document with unknown shapes still reports cleanly.
        if let probe = try? JSONDecoder().decode(VersionProbe.self, from: docData), probe.formatVersion > ShaderDocument.currentFormatVersion {
            throw .newerFormat(probe.formatVersion)
        }
        do { document = try JSONDecoder().decode(ShaderDocument.self, from: docData) }
        catch { throw .undecodable(String(describing: error)) }
        viewState = files[Self.viewFileName]?.regularFileContents.flatMap { try? JSONDecoder().decode(EditorViewState.self, from: $0) } ?? EditorViewState()
        var tex: [AssetID: Data] = [:], missing = Set<AssetID>()
        let dir = files[Self.texturesDirectory]?.fileWrappers ?? [:]
        for (id, info) in document.settings.assets {
            if let d = dir[Self.fileName(for: id, info: info)]?.regularFileContents { tex[id] = d } else { missing.insert(id) }
        }
        textures = tex; missingTextures = missing
    }

    public func fileWrapper() throws -> FileWrapper {
        let root = FileWrapper(directoryWithFileWrappers: [:])
        root.addRegularFile(withContents: try Self.encoder.encode(document), preferredFilename: Self.documentFileName)
        root.addRegularFile(withContents: try Self.encoder.encode(viewState), preferredFilename: Self.viewFileName)
        let dir = FileWrapper(directoryWithFileWrappers: [:])
        for (id, info) in document.settings.assets { if let d = textures[id] { dir.addRegularFile(withContents: d, preferredFilename: Self.fileName(for: id, info: info)) } }
        dir.preferredFilename = Self.texturesDirectory
        root.addFileWrapper(dir)
        return root
    }

    private struct VersionProbe: Decodable { let formatVersion: Int }
}
```

`ShaderDocument`'s own decoder must not also refuse newer versions with a different message (check; if it does, keep the probe first so `newerFormat` wins). The "sorted and indented" test asserts the first key is `definitions` — verify against the encoder's actual output (keys: `definitions`, `formatVersion`, `root`, `settings`).

- [ ] **Step 4: Run** the suite.

- [ ] **Step 5: Commit** — `feat(core): ShaderPackage — .mnshader FileWrapper read/write, tolerant view/texture loading, version gate`

---

### Task 4: DocumentGroup app, injected undo manager, starter document

**Files:**
- Create: `MetalNodes/ShaderFileDocument.swift`, `MetalNodes/DocumentHostView.swift`, `MetalNodesKit/Sources/MetalNodesCore/Library/StarterDocuments.swift`
- Modify: `MetalNodes/MetalNodesApp.swift`, `MetalNodes.xcodeproj/project.pbxproj` (Info.plist keys only), `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift`, `EditorModel+Undo.swift`, `EditorCommands.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorUndoInjectionTests.swift`, `MetalNodesCoreTests/LibraryM3Tests.swift` (starter validates)

**Interfaces:**
- Produces: `ShaderDocument.starter()` (UV at (0,0) → Fragment Output at (300,0), wired); `EditorModel.init(document:viewState:textures:compiler:registry:preview:pasteboard:undoManager:)` — `viewState` default `EditorViewState()`, `textures` default `[:]`, `undoManager: UndoManager? = nil` (nil → a private one, as today); `EditorModel.textures: [AssetID: Data]` (published; T6 mutates it via `importImage`); `EditorModel.missingTextures: Set<AssetID>` (seeded from the package; a warning diagnostic "Texture “name” is missing" per entry is appended to `diagnostics` after generation); `EditorModel.package: ShaderPackage` (computed: document + viewState + textures); `ShaderFileDocument: FileDocument` (`readableContentTypes = [.metalNodesShader]`, `init(configuration:)` → `ShaderPackage(fileWrapper:)`, `fileWrapper(configuration:)` → `package.fileWrapper()`); `UTType.metalNodesShader` (`com.maxburger.metalnodes.shader`, conforms to `.package`, extension `mnshader`); `DocumentHostView(file: Binding<ShaderFileDocument>, device:)` owning `@State model`, `@Environment(\.undoManager)`; `MetalNodesApp` uses `DocumentGroup(newDocument: ShaderFileDocument(package: ShaderPackage(document: .starter())))` and `.commands { EditorCommands() }`; Help ▸ "Open Sample Shader" (`NSDocumentController.shared.newDocument` then load the sample — simplest: a `CommandGroup(replacing: .help)` button that calls `openSample()` which writes the sample package to a temp `.mnshader` and opens it with `NSWorkspace`/`NSDocumentController.openDocument`).

- [ ] **Step 1: Tests** — `EditorUndoInjectionTests`: an `EditorModel` created with an external `UndoManager` registers its undo there (`external.canUndo == true` after `apply(.moveNodes(...))`, `undoActionName == "Move"`, `external.undo()` restores the position, `redo` works); the model without an injected manager behaves as before. `LibraryM3Tests`: `starter()` validates with no diagnostics and generates.

- [ ] **Step 2: Implement**
- `EditorModel`: `public let undoManager: UndoManager` becomes `private(set)`, initialised from the parameter or `UndoManager()`; `groupsByEvent = false` only for the private one (the environment manager is configured by AppKit — leave it; grouping still works because `commitUndo` opens/closes its own group). `EditorCommands`' `CommandGroup(replacing: .undoRedo)` stays (it reads the model's manager, which is now the window's) — but its `canvasFocused` gate must not block ⌘Z when focus is in the inspector text fields… keep the existing behaviour (M2 rule).
- `textures` / `missingTextures` / `package`; `compileNow` appends the missing-texture warnings (needs the manifest names) and updates `preview.textures` via a `TextureStore` owned by the model (created from the compiler's device — add `ShaderCompiling.device` or pass a `TextureStore?` in init; the test compiler has none → skip binding).
- `ShaderFileDocument`, `DocumentHostView`:

```swift
struct DocumentHostView: View {
    @Binding var file: ShaderFileDocument
    let device: MTLDevice
    let compiler: ShaderCompiler
    @Environment(\.undoManager) private var undoManager
    @State private var model: EditorModel?

    var body: some View {
        Group {
            if let model {
                EditorView(model: model, device: device)
                    .onChange(of: model.document) { _, d in file.package.document = d }
                    .onChange(of: model.viewState) { _, v in file.package.viewState = v }
                    .onChange(of: model.textures) { _, t in file.package.textures = t }
            } else {
                Color.clear.onAppear {
                    let m = EditorModel(document: file.package.document, viewState: file.package.viewState,
                                        textures: file.package.textures, compiler: compiler, undoManager: undoManager)
                    m.missingTextures = file.package.missingTextures
                    m.start(); model = m
                }
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}
```
`viewState` writes mark the document dirty too (spec §3 persists it; acceptable). The `undoManager` from the environment can be nil at first appearance — create the model in `.task`/`onAppear` and, if the manager arrives later, the model must be able to adopt it: give `EditorModel` a `func adoptUndoManager(_:)` that swaps the manager when its own stack is empty, called from `.onChange(of: undoManager)`.
- Info.plist (via the target's build settings in `project.pbxproj`): `CFBundleDocumentTypes` (name "MetalNodes Shader", `LSItemContentTypes` = `com.maxburger.metalnodes.shader`, `LSHandlerRank` Owner, `LSTypeIsPackage` true) and `UTExportedTypeDeclarations` (identifier, conforms to `com.apple.package`, extension `mnshader`). Commit only those key additions.
- `StarterDocuments.swift`: `ShaderDocument.starter()`.

- [ ] **Step 3: Build the app, run it**: File ▸ New opens a window with UV → Output; edit, ⌘S saves a `.mnshader` package (inspect its contents); reopen; undo titles work; dirty dot appears on edit. Then run the package suite.

- [ ] **Step 4: Commit** — `feat(app): DocumentGroup over .mnshader packages, window undo manager injected, starter document, Open Sample Shader`

---

### Task 5: `.metal` export for the fragment target

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Export/ShaderExport.swift`, `MetalNodesUI/Editor/EditorModel.swift` (`exportFiles` for `.fragment`), `InspectorView.swift` (enable Export… for the fragment target; the "Copy Swift snippet" stays stitchable-only)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/FragmentExportTests.swift`

**Interfaces:**
- Produces: `ShaderExport.files(for:registry:)` returns `[ExportFile(name: "<name>.metal", contents:)]` for `.fragment`; `ShaderExport.fragmentHeader(for shader: GeneratedShader, document:registry:) -> String` — lines `// MetalNodes fragment shader "<name>"`, `// Uniforms (buffer 0):`, one `//   <offset>  <type>  <name>  ← <node · param>` per field (reserved fields listed as `time`, `resolution`, `mouse`), `// Textures:` with `//   texture(<i>)  <asset name or "unassigned">`, then a blank line and the program source.

- [ ] **Step 1: Test** — golden for `ShaderDocument.sample()` under `.fragment` (whole-string compare of the header + the first line of the source), a textured document lists its slot, and `exportedMetalCompilesWithTheToolchainWhenAvailable`-style compile of the file (skip when `xcrun -sdk macosx metal` is unavailable — copy the pattern from `ShaderExportTests`).

- [ ] **Step 2: Implement**; `EditorModel.exportFiles` no longer requires a stitchable target; `ExportPanelMac.run(files:)` already handles a single file.

- [ ] **Step 3: Commit** — `feat: File ▸ Export… writes the fragment program as .metal with a layout header`

---

### Task 6: Texture import — image well, open panel, canvas drop, assets list

**Files:**
- Create: `MetalNodesUI/Editor/EditorModel+Assets.swift`, `MetalNodesUI/Editor/ImagePanelMac.swift`
- Modify: `Canvas/ParamControl.swift`, `Editor/InspectorView.swift`, `Canvas/GraphCanvasView.swift`, `Editor/EditorModel.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorAssetsTests.swift`

**Interfaces:**
- Produces: `EditorModel.importImage(data: Data, name: String) -> AssetID?` (decodes the pixel size with `CGImageSource` — allowed in UI; refuses undecodable data with `notice = "That file is not an image"`; adds the manifest entry through `apply(.setSettings(...))` in the caller's transaction and stores the bytes in `textures`); `EditorModel.assignAsset(_ asset: AssetID?, to node: NodeID)` (`.setParam(node, "asset", .asset(asset))`); `EditorModel.addTextureNode(imageData:name:at:) -> NodeID?` (one transaction "Add Texture": import + `addNode` with the asset assigned); `EditorModel.removeAsset(_:)` (only when unreferenced: removes the manifest entry and the bytes; "Remove Asset"); `EditorModel.isAssetReferenced(_:) -> Bool` (any node in any graph with `.asset(id)`); `ParamControl` `.asset` case renders an image well (thumbnail from the bytes via `NSImage(data:)` under `#if os(macOS)`, else a label) with "Choose…" (calls `onChooseImage`) and "Clear"; `ImagePanelMac.chooseImage() -> (Data, String)?` (`NSOpenPanel`, `allowedContentTypes: [.png, .jpeg, .heic]`); canvas `dropDestination(for: URL.self)` (and `Data`/image file promises) creating a Texture Sample at the drop point; inspector document settings gain an "Assets" list (name, pixel size, "Remove" enabled when unreferenced); the texture node's inspector shows the well.

- [ ] **Step 1: Tests** — `EditorAssetsTests` with a tiny PNG literal: `importImage` adds a manifest entry with the right pixel size and bytes; `addTextureNode` is one undo step (undo removes node and manifest entry; bytes may remain); `removeAsset` refuses while referenced, succeeds after the node is deleted; `isAssetReferenced` sees a node inside a definition; the missing-texture warning appears in `diagnostics` when `missingTextures` contains a referenced asset and disappears after `importImage` replaces it (re-import with the same `AssetID` — add `EditorModel.replaceAssetBytes(_:data:)`).

- [ ] **Step 2: Implement**; `preview.textures` refresh on `textures`/manifest change.

- [ ] **Step 3: Commit** — `feat(ui): image import via open panel and canvas drop, asset well, assets list with remove`

---

### Task 7: Clipboard carries texture bytes

**Files:**
- Modify: `MetalNodesCore/Clipboard/GraphClipboard.swift`, `MetalNodesUI/Editor/EditorModel+Clipboard.swift`, `EditorModel.swift` (`.insert` gains `assets: [AssetID: (AssetInfo, Data)]`)
- Test: `MetalNodesCoreTests/ClipboardTexturesTests.swift`, `MetalNodesUITests/EditorClipboardTests.swift`

**Interfaces:**
- Produces: `GraphClipboard.textures: [AssetID: Data]` and `assetInfos: [AssetID: AssetInfo]` (Codable — `Data` encodes as base64; tolerant decode with defaults); `GraphClipboard.extract(_:from:document:textures:)` collects the assets referenced by copied nodes and by the definitions carried; `DocumentChange.insert(nodes:edges:definitions:assets:)`; paste inserts manifest entries and bytes for assets the destination lacks (existing ids are kept as-is — never overwritten).

- [ ] **Step 1: Tests** — extract collects an asset referenced inside a carried definition; JSON round trip keeps bytes; pasting into an `EditorModel` whose document lacks the asset adds manifest + bytes and the node samples it; pasting where the asset exists leaves the destination's bytes untouched.

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat: clipboard carries referenced textures; paste adds the ones the destination lacks`

---

### Task 8: Comments — model and changes

**Files:**
- Modify: `MetalNodesCore/EditorViewState.swift` (`selectedComments`, `showsCode`, `showsMinimap` — tolerant Codable), `MetalNodesUI/Editor/DocumentChange.swift`, `EditorModel.swift`
- Create: `MetalNodesUI/Editor/EditorModel+Comments.swift`
- Test: `MetalNodesUITests/EditorCommentsTests.swift`, `MetalNodesCoreTests/NodeShapeTests.swift` (view-state decode with the new keys absent)

**Interfaces:**
- Produces: `CommentID { case sticky(StickyID), frame(FrameID) }` (Core, Hashable, Codable, Sendable); `EditorViewState.selectedComments: Set<CommentID> = []`, `showsCode = false`, `showsMinimap = true`; `DocumentChange` cases per §21.4 with `changeClass == .cosmetic` and the undo names listed there; `EditorModel.addSticky(at:) -> StickyID` (160×100, text "Note", accent `.muted`), `frameSelection() -> FrameID?` (bbox of the selected nodes' frames + 24 pt padding + 22 pt title bar above, title "Frame"), `members(of frame: FrameID) -> Set<NodeID>` (nodes whose frame centre lies inside), `moveFrame(_:by:)` (one transaction "Move Frame": `.moveComments` + `.moveNodes` of members), `selectComment(_:mode:)`, `clearSelection()` also clears comments, `deleteSelection()` also removes selected comments, `comment(at point:) -> CommentID?` (stickies before frames; a frame hits on its title bar or border band of 6 pt, not its interior — nodes and marquee inside frames must still work), `frameTitleBarHeight = 22`.

- [ ] **Step 1: Tests** — add sticky/frame apply + undo names; `frameSelection` geometry (exact rect for two known nodes); `members(of:)` by centre; `moveFrame` moves members and is one undo step; delete removes both node and comment selections; `comment(at:)` hit order; view state decodes without the new keys.

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat(ui): sticky notes and comment frames — changes, selection, geometry ownership, undo`

---

### Task 9: Comments — canvas, commands, inspector

**Files:**
- Create: `Canvas/CommentLayer.swift` (frames below wires, stickies above grid), `Canvas/FrameView.swift`, `Canvas/StickyView.swift`, `Editor/InspectorView+Comments.swift`
- Modify: `Canvas/GraphCanvasView.swift`, `Editor/EditorCommands.swift`, `Editor/InspectorView.swift`, `Theme/DraculaTheme.swift` (if a token is missing)

- [ ] **Step 1: Implement** per §21.4: frame = rounded rect, fill accent at 12 %, 1 pt border, title bar 22 pt (title text, accent), body hit-tests on the title bar / 6 pt border band; sticky = accent-tinted card with text (`Text`, 8 pt padding, wraps); both: selection outline (`selection` token), drag to move (`moveComments` / `moveFrame` through the model, one transaction per drag, `cancelTransaction` on cull like nodes), 12 pt corner handle → `.resizeComment` (min 80×40); marquee selects comments whose rect intersects; ⌫ deletes; Edit ▸ Add Sticky Note ⌘⇧N, Edit ▸ Frame Selection ⌘⇧C (disabled with empty selection); inspector panes: sticky (multi-line `TextEditor` bound to a draft, commits on focus loss / ⌘↩; accent picker), frame (title field on submit; accent picker). Clipboard copies selected comments too (`GraphClipboard.stickies/frames` already exist — `extract` fills them from `selectedComments`; paste offsets them with the nodes).

- [ ] **Step 2: App hand check** (controller): add note, type, resize, move; frame two nodes, drag the frame → nodes follow; drag a node out → stays behind on the next frame drag; undo/redo names; copy/paste a frame with nodes.

- [ ] **Step 3: Commit** — `feat(ui): draw, select, move, resize and edit sticky notes and comment frames; ⌘⇧N / ⌘⇧C`

---

### Task 10: Line map covers group functions; delete dead code

**Files:**
- Modify: `Codegen/GroupCodegen.swift` (`GroupFunction.bodyOwners: [NodeID?]` parallel to the *function's own lines* — build the function through a `SourceBuilder` and keep its `map`), `Codegen/ShaderGenerator.swift` (+Viewer) — when adding a function's source, offset its entries by the current line count into the program's `LineMap`; delete `ShaderGenerator.diagnostics(_:)`
- Test: `MetalNodesCoreTests/LineMapGroupTests.swift`

- [ ] **Step 1: Test** — for `GroupCodegenTests.twice()`-shaped document: `lineMap.lines(for: mathNodeInsideDefinition)` is non-empty and every line in it contains `v1 = v0 + v0;` or its declaration; root node lines unchanged; a viewer program through the instance maps the inner node too; an unowned line (`struct G_…`) maps to nil.

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat(core): line map covers group-function bodies; remove ShaderGenerator.diagnostics`

---

### Task 11: Generated-code panel

**Files:**
- Create: `Editor/MSLHighlighter.swift`, `Editor/CodePanel.swift`
- Modify: `Editor/EditorView.swift` (preview column becomes `VSplitView { previewPane; if showsCode { CodePanel } }` on macOS, `VStack` on iPad), `Editor/EditorCommands.swift` (View ▸ Generated Code ⌘⌥C, toggles `viewState.showsCode`), `Editor/EditorModel.swift` (`generatedLineMap: LineMap` published alongside `generatedSource`)
- Test: `MetalNodesUITests/MSLHighlighterTests.swift`

**Interfaces:**
- Produces: `MSLHighlighter.attributed(_ source: String, highlightLines: Set<Int>) -> AttributedString` — token classes keyword (`float`, `float2`…`half4`, `struct`, `return`, `constant`, `texture2d`, `sampler`, `fragment`, `using`, `namespace`, attributes in `[[…]]`), number, comment (`//` to end of line), preprocessor (`#include`), identifier; colours via `DraculaToken` (`purple` keywords, `orange` numbers, `comment` comments, `pink` preprocessor, `foreground` identifiers), highlighted lines get `currentLine` background; `CodePanel(model:)` — monospaced `Text(attributed)` in a `ScrollView`, a Copy button (`model.pasteboard`… reuse the Pasteboarding protocol), selection → highlight lines from `generatedLineMap.lines(for:)` of the single selected node.

- [ ] **Step 1: Tests** — highlighter: a keyword run has the purple foreground, a `//` comment run has the comment colour, `#include` pink, a line in `highlightLines` has the background; unknown text is foreground; empty input → empty output.

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat(ui): generated-code panel with Dracula highlighting, copy, and selected-node line highlight`

---

### Task 12: Minimap

**Files:**
- Create: `Canvas/MinimapLayout.swift`, `Canvas/MinimapView.swift`
- Modify: `Canvas/GraphCanvasView.swift` (overlay bottom-right, 12 pt inset), `Editor/EditorCommands.swift` (View ▸ Minimap ⌘⌥M → `viewState.showsMinimap`)
- Test: `MetalNodesUITests/MinimapLayoutTests.swift`

**Interfaces:**
- Produces: `MinimapLayout(size: CGSize = 180×120, graphBounds: CGRect, viewport: CGRect)` with `scale: CGFloat`, `func mapRect(_ canvasRect: CGRect) -> CGRect`, `func canvasPoint(_ mapPoint: CGPoint) -> CGPoint`; the map fits `graphBounds ∪ viewport` with 8 pt padding, aspect-preserving, centred; `MinimapView(model:)` draws node rects (category colour, accent for instances) and frame outlines from `model.graph` + `model.shapes`, the viewport as a `foreground` 1 pt rect, and on click/drag calls `model.requestCanvas(.centerOn(point))` (new `CanvasRequest.centerOn(CGPoint)` handled by the canvas: pan so the point is at the viewport centre).

- [ ] **Step 1: Tests** — layout maths: a 1000×500 graph in a 180×120 map → scale 0.164 (`(180-16)/1000`), centred vertically; `canvasPoint(mapRect(p).origin) == p` round trip; viewport outside the graph bounds extends the fitted area.

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat(ui): minimap overlay with click-to-centre; View ▸ Minimap`

---

### Task 13: ⇧A definitions

**Files:**
- Modify: `Palette/NodeSearchPopover.swift`, `Palette/PaletteSearch.swift`, `Canvas/GraphCanvasView.swift`
- Test: `MetalNodesUITests/NodeSearchRowsTests.swift`

**Interfaces:**
- Produces: `enum SearchRow: Identifiable { case builtin(NodeDef), definition(GroupDefinition) }`; `PaletteSearch.rows(query:registry:document:) -> [SearchRow]` (builtins as today, then definitions matching by name, sorted by name); `NodeSearchPopover(rows:onPick:onCancel:)`; picking a definition → `model.addInstance(of:at:)` at the chooser point, wired to the pending wire like a builtin when compatible (first compatible input via the shape) — recursion refused with the notice and the chooser dismissed.

- [ ] **Step 1: Tests** — `rows` ordering and filtering (empty query lists all builtins then all definitions; "gro" matches "Group"; a builtin-only query lists no definitions).

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `feat(ui): ⇧A search lists group definitions`

---

### Task 14: Shape cache and cleanups

**Files:**
- Modify: `Editor/EditorModel.swift` (`shapes: [NodeID: NodeShape]` rebuilt lazily: a `shapesVersion` bumped in `perform` and on `activePath` change; `activeShapes` closure reads the cache), `Canvas/NodeGeometry.swift`, `Canvas/DropResolver.swift` (delete the `registry:` overloads and `rootShapes`), the tests that used them (`NodeGeometryTests`, `DropResolverTests` → build a root-only document and pass `{ doc.shape(of: $0, in: .root, registry: reg) }`)
- Test: `MetalNodesUITests/ShapeCacheTests.swift`

- [ ] **Step 1: Tests** — the cache returns the same dictionary instance-equal across two reads without edits; changes after `apply(.addNode)`; changes after `diveIn` (pseudo-nodes appear); registry overloads gone (compile-time).

- [ ] **Step 2: Implement.** — [ ] **Step 3: Commit** — `refactor(ui): cached NodeShapes per active graph; drop registry-based geometry overloads`

---

### Task 15: Integration — build, suite, greps, manual checklist

- [ ] **Step 1**: `swift build` warning-free; `swift test`; GPU `ShaderCompilerTests` incl. textured programs; `xcodebuild … build`; `git diff MetalNodes.xcodeproj/project.pbxproj` shows only the Info.plist keys from T4.
- [ ] **Step 2: Greps**: hex outside DraculaTheme; Core imports; AppKit gating; no `document.root` in UI outside `EditorModel`.
- [ ] **Step 3: Manual checklist** (controller, computer-use; record observed/failed; fixes committed as `fix(…): … — manual check N`):
  1. File ▸ New → UV → Output window; title "Untitled"; edit → dirty dot; ⌘S → `Test.mnshader`; Finder shows a single file; `document.json`/`view.json`/`textures/` inside.
  2. Close, reopen from Finder → graph, camera and selection restored; Edit ▸ Undo titles come from the window ("Undo Move").
  3. Help ▸ Open Sample Shader → the demo in a new window.
  4. Palette ▸ Texture Sample → node with an empty image well; preview shows the magenta/black placeholder through the node; "Choose…" → pick a PNG → thumbnail, preview shows the image, upright (uv.y=0 at the bottom).
  5. Drop a JPEG from Finder onto the canvas → Texture Sample at the drop point with the image; ⌘Z removes node and manifest entry.
  6. Two Texture Samples of the same image → export header lists one texture slot; a second, different image → two slots.
  7. Document settings ▸ Assets: Remove disabled while referenced; delete the node → enabled; Remove → gone from the list; save → file gone from `textures/`.
  8. Group a Texture Sample (⌘G) → still renders; export shows `texture2d<float> t_…` parameter on the group function.
  9. Target Color Effect with a Texture Sample → error outline + "Texture Sample needs the Layer Effect target"; Layer Effect → preview shows the image; export contains `layer.sample(position)`.
  10. Gradient and Checker nodes render; angle/scale sliders live (no recompile); shape popup recompiles.
  11. Fragment target ▸ File ▸ Export… → one `.metal`; header lists uniforms with node · param names and textures; `xcrun metal -c` compiles it.
  12. Copy a Texture Sample, paste into a new document → image comes along (thumbnail + render); paste again → no duplicate asset.
  13. Delete the image file from the package in Finder, reopen → warning "Texture “x.png” is missing" in the diagnostics, placeholder renders; Choose… a new file → warning clears.
  14. ⌘⇧N → sticky at centre; type in the inspector; resize by the corner; accent picker; ⌫ deletes; ⌘Z restores with text.
  15. Select two nodes, ⌘⇧C → frame around them; drag the frame → nodes follow; drag a node out, drag the frame → it stays; title edit; frame selected + node selected + ⌫ → both gone, one ⌘Z restores.
  16. Frames draw behind wires; stickies above the grid; marquee inside a frame selects nodes, not the frame.
  17. View ▸ Generated Code → pane; select a node → its lines highlighted; select a node inside a definition → its lines in the group function highlighted; Copy → clipboard has the source; a broken graph still updates the panel.
  18. View ▸ Minimap → overlay; click far right → viewport centres there; dive into a group → minimap shows the definition graph; toggle persists after reopen.
  19. ⇧A, type "gro" → "Group" under My Functions → placed; inside its own definition → notice.
  20. Drag a 200-node selection (paste the sample 20×) inside a definition → smooth (shape cache).

## Done criteria for this plan

- Documents open, save, autosave and reopen as `.mnshader` packages with textures; undo is the window's; the starter and sample flows work.
- Texture Sample, Gradient, Checker in the library; textures bound in the preview; slots through groups; Layer Effect export; fragment `.metal` export with a header.
- Comments, code panel, minimap, ⇧A definitions on the canvas; shape cache in place; dead code gone.
- Suite green, warning-free, greps clean, 20 manual checks observed.

## What the next plan (M6) starts from

iPadOS UI layer (touch input map, split views, share sheet for export), pasteboard images as textures, frame collapse, socket reordering, cross-document paste polish (asset name clashes), `.metallib` export if the toolchain is present.
