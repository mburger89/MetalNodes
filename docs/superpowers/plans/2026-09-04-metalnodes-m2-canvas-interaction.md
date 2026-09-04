# MetalNodes M2 — Canvas Interaction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the M1 editor (a rendered sample graph you can nudge) into a real node editor: select, wire, add from a palette, undo, copy/paste, inspect — with the M1 review's four carry-overs closed first.

**Architecture:** Every edit still flows through `EditorModel.apply(_ change: DocumentChange)`; M2 widens `DocumentChange` (multi-move, remove-set, insert, title, settings, restore), wraps applies in snapshot **transactions** that register with an `UndoManager` the model owns, and adds selection, pasteboard and node-placement operations on the model so views stay thin. Pure geometry (node frames, marquee hits, wire distance, zoom-to-fit, drop resolution, palette search) lives in small tested enums. The canvas gains a scroll-wheel overlay, keyboard focus, marquee, rubber-band wiring, a palette drop target and culling/LOD; a `Commands` scene routes the Edit menu to the focused model.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 / iPadOS 27), AppKit for pasteboard + scroll-wheel monitor (macOS branch only), Metal, Swift Testing, SwiftPM local package.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §5 (undo), §6 (copy/paste), §11.1–11.4 (canvas, input map, connection UX, palette), §12 (theme), and **§18 (M2 addendum)** which pins the mechanics. Read §18 in full before any task.

## Global Constraints

- Swift language mode `6`, strict concurrency, warning-free build (`swift build --package-path MetalNodesKit 2>&1 | grep -i warning` prints nothing).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics`. `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore` (+ SwiftUI only in `PreviewView.swift`). `MetalNodesUI` may import AppKit **only** inside `#if os(macOS)` / `#if canImport(AppKit)` and only in files whose name ends in `Mac.swift` or in a clearly gated section; the `#else` branch must keep the iPad build plausible.
- `MetalNodesUI` and `MetalNodesUITests` have `.defaultIsolation(MainActor.self)`; Core and Render do not.
- Colors only through `DraculaTheme` / `DraculaToken`. No hex literals outside `DraculaTheme.swift`. Selection = 2 pt `foreground` outline + glow (no hue). Red = errors only. Viewer flag = green ◉ (M3).
- Every edit goes through `EditorModel.apply(_:)`; views never mutate `document` directly. Classification stays: cosmetic → nothing; parameter → uniform write, no compile; topology → debounced compile.
- Undo = whole-document snapshots in transactions (spec §5, §18.3). View state (`EditorViewState`) is never snapshotted; after `restore`, selection ∩ surviving nodes.
- Pasteboard type string: `com.maxburger.metalnodes.graph` (JSON `GraphClipboard`, spec §18.4). Node-def drag type: `com.maxburger.metalnodes.nodedef`.
- Wire drop resolution order (spec §18.5): socket within 14 canvas pt → node body → empty canvas. Incompatible sockets render at 30 % opacity during a drag.
- Culling margin 200 pt; LOD (header-only) below zoom `0.4` (spec §18.9). Node width stays `190`.
- Tests: Swift Testing only. Package suite: `swift test --package-path MetalNodesKit`. App build: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- Never commit `MetalNodes.xcodeproj/project.pbxproj` key reorders (`git checkout -- MetalNodes.xcodeproj/project.pbxproj` before committing) or the `xcshareddata/` directory `xcodebuild` sometimes creates.

---

## File structure

```
MetalNodesKit/Sources/
  MetalNodesCore/
    Graph.swift                          modify — public `Edge`, `Graph.edgeList`, `Graph.internalEdges(among:)`
    ShaderDocument.swift                 modify — `DocumentSettings.fastMath` + tolerant Codable
    Clipboard/GraphClipboard.swift       create — extract / materialize subgraphs with ID remapping
  MetalNodesRender/
    ShaderCompiler.swift                 modify — CompileSeverity, LRU cache, fastMath key, superseded failures
    ShaderCompiling.swift                modify — fastMath parameter
  MetalNodesUI/
    Editor/DocumentChange.swift          modify — M2 cases (§18.2)
    Editor/EditorModel.swift             modify — apply cases, transactions, selection, clipboard ops, placement
    Editor/EditorModel+Undo.swift        create — transaction / undo / redo
    Editor/EditorModel+Selection.swift   create — select / delete / nudge / frames
    Editor/EditorModel+Clipboard.swift   create — copy / cut / paste / duplicate
    Editor/Pasteboarding.swift           create — protocol + MemoryPasteboard
    Editor/SystemPasteboardMac.swift     create — NSPasteboard implementation (#if os(macOS))
    Editor/EditorCommands.swift          create — Commands scene + FocusedValue key
    Editor/EditorView.swift              modify — three panes, focused value, inspector
    Editor/InspectorView.swift           create — §18.8
    Canvas/NodeGeometry.swift            create — estimated sizes, frames, marquee hits, fit math
    Canvas/DropResolver.swift            create — §18.5 drop order (pure)
    Canvas/WireLayer.swift               modify — selected wire, rubber band, distance()
    Canvas/SocketView.swift              modify — dimmed state, drag start hooks
    Canvas/NodeView.swift                modify — selection outline, multi-drag, compact LOD, transactions
    Canvas/ParamControl.swift            modify — onEditing begin/end for slider transactions
    Canvas/GraphCanvasView.swift         modify — marquee, wiring state, keyboard, culling, drop target
    Canvas/ScrollWheelCatcherMac.swift   create — NSEvent local monitor (#if os(macOS))
    Canvas/CanvasTransform.swift         modify — `fitting(rect:in:padding:)`
    Palette/PaletteSearch.swift          create — filter + rank (pure)
    Palette/NodeDefTransfer.swift        create — Transferable for drag-out
    Palette/PaletteView.swift            create — sidebar
    Palette/NodeSearchPopover.swift      create — ⇧A / double-click / wire-drop popover
MetalNodesKit/Tests/
  MetalNodesCoreTests/GraphClipboardTests.swift        create
  MetalNodesCoreTests/GraphCodableTests.swift          modify — Edge/edgeList
  MetalNodesCoreTests/DocumentSettingsTests.swift      create
  MetalNodesRenderTests/ShaderCompilerTests.swift      modify — severity, LRU, fastMath, superseded failure
  MetalNodesUITests/EditorModelTests.swift             modify — new cases, RecordingCompiler signature, severity mapping
  MetalNodesUITests/EditorUndoTests.swift              create
  MetalNodesUITests/EditorSelectionTests.swift         create
  MetalNodesUITests/EditorClipboardTests.swift         create
  MetalNodesUITests/NodeGeometryTests.swift            create
  MetalNodesUITests/DropResolverTests.swift            create
  MetalNodesUITests/WireGeometryTests.swift            modify — distance()
  MetalNodesUITests/CanvasTransformTests.swift         modify — fitting()
  MetalNodesUITests/PaletteSearchTests.swift           create
MetalNodes/MetalNodesApp.swift                          modify — `.commands { EditorCommands() }`
```

Task order follows spec §18.1: carry-overs (1–2) → change model (3) → undo (4) → selection (5–6) → wiring (7–8) → input (9) → palette (10–11) → clipboard (12–13) → inspector (14) → culling/LOD (15) → integration (16).

---

### Task 1: ShaderCompiler carry-overs — severity, LRU cache, fastMath key, superseded failures

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiler.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiling.swift`
- Modify: `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift`

**Interfaces:**
- Consumes: `GeneratedShader` (public init available), `MTLCompileOptions.mathMode`.
- Produces:
  - `enum CompileSeverity: String, Sendable, Hashable { error, warning, note }`
  - `struct CompileLine { line: Int; severity: CompileSeverity; message: String; init(line:severity:message:) }` — `severity` defaults to `.error` in the init.
  - `ShaderCompiler.init(device:pixelFormat: = .bgra8Unorm, cacheLimit: Int = 64)`; `func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool = true) async -> CompileResult`; `func isCached(_ shader: GeneratedShader, fastMath: Bool = true) -> Bool`; `var cacheCount`.
  - `protocol ShaderCompiling { func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult }`.
  - A `.failure` whose generation is below `latestRequested` now returns `.superseded` (symmetric with `.success`).

- [ ] **Step 1: Update and extend the tests**

In `ShaderCompilerTests.swift`, replace `parsesClangStyleLines` and add four tests. The helper `variant(_:tag:)` makes a distinct-but-valid source by appending a comment.

```swift
    private func variant(_ shader: GeneratedShader, tag: Int) -> GeneratedShader {
        GeneratedShader(source: shader.source + "\n// variant \(tag)\n", layout: shader.layout, lineMap: shader.lineMap,
                        resolved: shader.resolved, fragmentFunctionName: shader.fragmentFunctionName, target: shader.target)
    }

    @Test func parsesClangStyleLinesWithSeverity() {
        let msg = """
        program_source:42:9: error: use of undeclared identifier 'retrun'
        program_source:50:1: warning: unused variable 'v3'
        program_source:12:3: note: expanded from macro
        """
        #expect(ShaderCompiler.parseLines(msg) == [
            CompileLine(line: 42, severity: .error, message: "use of undeclared identifier 'retrun'"),
            CompileLine(line: 50, severity: .warning, message: "unused variable 'v3'"),
            CompileLine(line: 12, severity: .note, message: "expanded from macro"),
        ])
    }

    @Test func lruEvictsTheLeastRecentlyUsedPipeline() async throws {
        let d = try #require(Self.device)
        let c = try ShaderCompiler(device: d, cacheLimit: 2)
        let base = try ShaderGenerator.generate(ShaderDocument.sample())
        let a = variant(base, tag: 1), b = variant(base, tag: 2), x = variant(base, tag: 3)
        _ = await c.compile(a, generation: 1)
        _ = await c.compile(b, generation: 1)
        _ = await c.compile(a, generation: 1)          // touch a → b is now least recent
        _ = await c.compile(x, generation: 1)          // evicts b
        #expect(await c.cacheCount == 2)
        #expect(await c.isCached(a))
        #expect(await c.isCached(x))
        #expect(await c.isCached(b) == false)
    }

    @Test func fastMathIsPartOfTheCacheKey() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 1, fastMath: true)
        _ = await c.compile(shader, generation: 1, fastMath: false)
        #expect(await c.cacheCount == 2)
        #expect(await c.isCached(shader, fastMath: false))
    }

    @Test func staleFailureIsSuperseded() async throws {
        let c = try compiler()
        let good = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(good, generation: 2)
        var broken = variant(good, tag: 9)
        broken = GeneratedShader(source: broken.source.replacingOccurrences(of: "return", with: "retrun"),
                                 layout: broken.layout, lineMap: broken.lineMap, resolved: broken.resolved,
                                 fragmentFunctionName: broken.fragmentFunctionName, target: broken.target)
        guard case .superseded(let g) = await c.compile(broken, generation: 1) else {
            Issue.record("expected superseded, not failure, for a stale broken compile"); return
        }
        #expect(g == 1)
    }
```

Also update the existing `brokenSourceReportsFailureWithLine` expectation to check severity: after `#expect(lines.first!.line > 1)` add `#expect(lines.first!.severity == .error)`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests 2>&1 | grep -E 'error:' | head -5`
Expected: compile errors — `CompileSeverity` not found, extra argument `cacheLimit`, `isCached` missing.

- [ ] **Step 3: Rewrite `ShaderCompiler.swift`**

```swift
import Foundation
import Metal
import MetalNodesCore

/// A ready-to-draw pipeline plus the shader it was built from.
/// `MTLRenderPipelineState` is documented thread-safe, hence `@unchecked`.
public struct CompiledPipeline: @unchecked Sendable {
    public let state: MTLRenderPipelineState
    public let shader: GeneratedShader
    public let generation: UInt64
}

public enum CompileSeverity: String, Sendable, Hashable {
    case error, warning, note
}

public struct CompileLine: Sendable, Hashable {
    public let line: Int
    public let severity: CompileSeverity
    public let message: String
    public init(line: Int, severity: CompileSeverity = .error, message: String) {
        self.line = line; self.severity = severity; self.message = message
    }
}

public enum CompileResult: Sendable {
    case success(CompiledPipeline)
    case failure(message: String, lines: [CompileLine], generation: UInt64)
    case superseded(generation: UInt64)
}

public enum ShaderCompilerError: Error { case vertexFunctionMissing, fragmentFunctionMissing }

/// Compiles generated MSL off the main actor. LRU cache keyed by (source, fastMath);
/// latest generation wins for both success and failure (spec §9.6, §10, §18.1).
public actor ShaderCompiler {
    private struct CacheKey: Hashable { let source: String; let fastMath: Bool }

    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let pixelFormat: MTLPixelFormat
    private var cache: [CacheKey: MTLRenderPipelineState] = [:]
    private var lru: [CacheKey] = []          // least recent first
    private var latestRequested: UInt64 = 0
    public let cacheLimit: Int

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm, cacheLimit: Int = 64) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        self.cacheLimit = max(1, cacheLimit)
        let lib = try device.makeLibrary(source: VertexStage.source, options: nil)
        guard let fn = lib.makeFunction(name: VertexStage.functionName) else { throw ShaderCompilerError.vertexFunctionMissing }
        vertexFunction = fn
    }

    public var cacheCount: Int { cache.count }

    public func isCached(_ shader: GeneratedShader, fastMath: Bool = true) -> Bool {
        cache[CacheKey(source: shader.source, fastMath: fastMath)] != nil
    }

    public func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool = true) async -> CompileResult {
        latestRequested = max(latestRequested, generation)
        let key = CacheKey(source: shader.source, fastMath: fastMath)

        if let hit = cache[key] {
            touch(key)
            return finish(hit, shader, generation)
        }
        do {
            let options = MTLCompileOptions()
            // Fast math is a document-level choice (spec §18.1): it relaxes NaN/Inf/denormal
            // semantics for every node. `.safe` keeps IEEE behaviour.
            options.mathMode = fastMath ? .fast : .safe
            let lib = try await device.makeLibrary(source: shader.source, options: options)
            guard let frag = lib.makeFunction(name: shader.fragmentFunctionName) else {
                throw ShaderCompilerError.fragmentFunctionMissing
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let state = try await device.makeRenderPipelineState(descriptor: desc)
            insert(key, state)
            return finish(state, shader, generation)
        } catch {
            if generation < latestRequested { return .superseded(generation: generation) }
            let msg = error.localizedDescription
            return .failure(message: msg, lines: ShaderCompiler.parseLines(msg), generation: generation)
        }
    }

    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        generation < latestRequested
            ? .superseded(generation: generation)
            : .success(CompiledPipeline(state: state, shader: shader, generation: generation))
    }

    private func touch(_ key: CacheKey) {
        lru.removeAll { $0 == key }
        lru.append(key)
    }

    private func insert(_ key: CacheKey, _ state: MTLRenderPipelineState) {
        cache[key] = state
        touch(key)
        while lru.count > cacheLimit {
            let evicted = lru.removeFirst()
            cache[evicted] = nil
        }
    }

    /// Pulls `program_source:LINE:COL: (error|warning|note): message` entries out of a Metal compiler message.
    public static func parseLines(_ message: String) -> [CompileLine] {
        let pattern = /program_source:(\d+):\d+:\s*(error|warning|note):\s*([^\n]*)/
        return message.matches(of: pattern).compactMap { m in
            guard let line = Int(m.1), let sev = CompileSeverity(rawValue: String(m.2)) else { return nil }
            return CompileLine(line: line, severity: sev, message: String(m.3).trimmingCharacters(in: .whitespaces))
        }
    }
}
```

If `MTLMathMode.safe` is unavailable on this SDK, use `.relaxed` for the non-fast case and say so in the report.

- [ ] **Step 4: Update `ShaderCompiling.swift`**

```swift
import MetalNodesCore

/// Abstracts `ShaderCompiler` so the editor can be tested without a GPU.
public protocol ShaderCompiling: Sendable {
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult
}

extension ShaderCompiler: ShaderCompiling {}
```

The UI test target's `RecordingCompiler` will stop compiling until Task 2 updates it — that is expected; this task's gate is `--filter ShaderCompilerTests` plus `swift build` of the Render target (`swift build --package-path MetalNodesKit --target MetalNodesRender`).

- [ ] **Step 5: Run the Render tests**

Run: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests 2>&1 | tail -3`
Expected: all ShaderCompilerTests pass (11 tests).

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender MetalNodesKit/Tests/MetalNodesRenderTests
git commit -m "feat(render): compile severity, LRU pipeline cache, fastMath key, superseded failures

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 2: `DocumentSettings.fastMath` and editor severity mapping

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift:22-26`
- Create: `MetalNodesKit/Tests/MetalNodesCoreTests/DocumentSettingsTests.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift:120-138`
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift:9-15` (RecordingCompiler) and add one test

**Interfaces:**
- Produces: `DocumentSettings.fastMath: Bool` (default `true`; decoding JSON without the key yields `true`). `EditorModel` passes `document.settings.fastMath` to the compiler, maps `CompileSeverity` → `Diagnostic.Severity` (`.error` → `.error`, `.warning`/`.note` → `.warning`), keeps unmapped lines as node-less diagnostics, and clears `preview.lastError` on the structural-invalid path.

- [ ] **Step 1: Write the failing Core test**

`DocumentSettingsTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct DocumentSettingsTests {
    @Test func fastMathDefaultsOnAndRoundTrips() throws {
        var s = DocumentSettings()
        #expect(s.fastMath == true)
        s.fastMath = false
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: data).fastMath == false)
    }

    @Test func missingFastMathKeyDecodesAsTrue() throws {
        let legacy = #"{"previewSize":[512,512],"timeMode":"wallClock"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(DocumentSettings.self, from: legacy)
        #expect(s.fastMath == true)
        #expect(s.timeMode == .wallClock)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter DocumentSettingsTests 2>&1 | grep error: | head -3`
Expected: `value of type 'DocumentSettings' has no member 'fastMath'`.

- [ ] **Step 3: Replace `DocumentSettings` in `ShaderDocument.swift`**

```swift
public struct DocumentSettings: Sendable, Hashable {
    public var previewSize: CGSize = CGSize(width: 512, height: 512)
    public var timeMode: TimeMode = .wallClock
    /// Metal fast-math for every compiled shader (spec §18.1). Part of the pipeline cache key.
    public var fastMath: Bool = true
    public init() {}
}

extension DocumentSettings: Codable {
    private enum Keys: String, CodingKey { case previewSize, timeMode, fastMath }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        previewSize = try c.decodeIfPresent(CGSize.self, forKey: .previewSize) ?? CGSize(width: 512, height: 512)
        timeMode = try c.decodeIfPresent(TimeMode.self, forKey: .timeMode) ?? .wallClock
        fastMath = try c.decodeIfPresent(Bool.self, forKey: .fastMath) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(previewSize, forKey: .previewSize)
        try c.encode(timeMode, forKey: .timeMode)
        try c.encode(fastMath, forKey: .fastMath)
    }
}
```

- [ ] **Step 4: Update the UI test fake and add the severity test**

In `EditorModelTests.swift`, change `RecordingCompiler.compile` to the new signature and add a second fake plus a test:

```swift
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
```

and, inside the suite:

```swift
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
```

- [ ] **Step 5: Update `EditorModel.compileNow`**

Replace the block from `switch await compiler.compile(shader, generation: gen) {` through the end of the `.failure` case with:

```swift
        switch await compiler.compile(shader, generation: gen, fastMath: doc.settings.fastMath) {
        case .success(let pipeline):
            guard pipeline.generation == generation else { return }
            preview.pipeline = pipeline
            preview.uniforms = UniformImage.rebuild(layout: pipeline.shader.layout, document: document, registry: registry)
            preview.lastError = nil
        case .failure(let message, let lines, let g):
            guard g == generation else { return }
            preview.lastError = message
            var mapped: [Diagnostic] = []
            for l in lines {
                let sev: Diagnostic.Severity = l.severity == .error ? .error : .warning
                mapped.append(Diagnostic(sev, l.message, node: shader.lineMap.node(forLine: l.line)))
            }
            diagnostics = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
```

and in the `.failure(let error)` branch of the `result` switch (structural-invalid path), add `preview.lastError = nil` before `return` so a stale Metal error never outlives the structural diagnostics that replaced it.

- [ ] **Step 6: Run the full suite**

Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'`
Expected: three green summary lines; the Core count grows by 2, UI by 2.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat: DocumentSettings.fastMath; map compiler severity into diagnostics

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 3: Public `Edge`, `DocumentChange` v2, and the widened `apply`

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Graph.swift` (the `Graph` struct and its `Codable` extension)
- Modify: `MetalNodesKit/Tests/MetalNodesCoreTests/GraphCodableTests.swift` (add two tests)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/DocumentChange.swift` (replace file)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift:53-82` (`apply`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift:51` (`.moveNode` → `.moveNodes`)
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift` (three call sites + new tests)

**Interfaces:**
- Produces (Core): `public struct Edge: Codable, Sendable, Hashable { var to: SocketRef; var from: SocketRef; init(to:from:) }`; `Graph.edgeList: [Edge]` (sorted by `(to.node UUID, to.socket)`); `Graph.internalEdges(among: Set<NodeID>) -> [Edge]`; `mutating Graph.remove(nodes: Set<NodeID>)`.
- Produces (UI): `DocumentChange` cases `moveNodes([NodeID: CGPoint])`, `setParam`, `setTitle(NodeID, String?)`, `connect`, `disconnect`, `addNode`, `removeNodes(Set<NodeID>)`, `insert(nodes: [NodeInstance], edges: [Edge])`, `setSettings(DocumentSettings)`, `restore(ShaderDocument)`; `changeClass`; `undoName: String`. `moveNode`/`removeNode` are gone.
- `EditorModel.apply` handles every case; after `removeNodes` and `restore`, `viewState.selection` is intersected with surviving node IDs.

- [ ] **Step 1: Write the failing Core tests**

Append to `GraphCodableTests`:

```swift
    @Test func internalEdgesOnlyIncludeEdgesWithBothEndsInside() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("input.time"))
        g.nodes[c.id] = c
        g.connect(SocketRef(c.id, "time"), to: SocketRef(b, "color"))   // replaces a→b
        g.connect(SocketRef(a, "uv"), to: SocketRef(c.id, "x"))         // a→c (nonsense socket, fine for the graph type)
        #expect(g.internalEdges(among: [a, c.id]) == [Edge(to: SocketRef(c.id, "x"), from: SocketRef(a, "uv"))])
        #expect(g.internalEdges(among: [b]).isEmpty)
        #expect(g.edgeList.count == 2)
    }

    @Test func removeNodesDropsAllTouchingWiresInOneCall() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("math.math"))
        g.nodes[c.id] = c
        g.connect(SocketRef(a, "uv"), to: SocketRef(c.id, "a"))
        g.remove(nodes: [a, c.id])
        #expect(g.nodes.keys.sorted { $0.raw.uuidString < $1.raw.uuidString } == [b])
        #expect(g.inputs.isEmpty)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter GraphCodableTests 2>&1 | grep error: | head -3`
Expected: `cannot find 'Edge' in scope` / no member `internalEdges`.

- [ ] **Step 3: Edit `Graph.swift`**

Add the public `Edge` above `Graph` (and delete the `private struct Edge` inside the Codable extension):

```swift
/// One wire. `to` is the input socket (unique per graph), `from` its source output.
public struct Edge: Codable, Sendable, Hashable {
    public var to: SocketRef
    public var from: SocketRef
    public init(to: SocketRef, from: SocketRef) { self.to = to; self.from = from }
}
```

Add to `Graph` (after `upstreamNodes(of:)`):

```swift
    /// Every wire, sorted by input socket so output is deterministic.
    public var edgeList: [Edge] {
        inputs.map { Edge(to: $0.key, from: $0.value) }
            .sorted { ($0.to.node.raw.uuidString, $0.to.socket) < ($1.to.node.raw.uuidString, $1.to.socket) }
    }

    /// Wires whose both ends are inside `ids` — the edges a copy/group operation keeps.
    public func internalEdges(among ids: Set<NodeID>) -> [Edge] {
        edgeList.filter { ids.contains($0.to.node) && ids.contains($0.from.node) }
    }

    /// Removes several nodes and every wire touching any of them.
    public mutating func remove(nodes ids: Set<NodeID>) {
        for id in ids { nodes[id] = nil }
        inputs = inputs.filter { !ids.contains($0.key.node) && !ids.contains($0.value.node) }
    }
```

In the `Codable` extension, `encode` becomes `try c.encode(edgeList, forKey: .edges)` and `decode` stays `try c.decode([Edge].self, forKey: .edges)` (now the public type). The JSON shape is unchanged (`to`/`from` keys).

- [ ] **Step 4: Run Core tests**

Run: `swift test --package-path MetalNodesKit --filter GraphCodableTests 2>&1 | tail -2`
Expected: all pass (8 tests).

- [ ] **Step 5: Replace `DocumentChange.swift`**

```swift
import CoreGraphics
import MetalNodesCore

public enum ChangeClass: Sendable { case cosmetic, parameter, topology }

/// Every edit goes through one of these, which is what makes classification
/// (spec §10) a `switch` instead of a diff. Spec §18.2 lists the M2 set.
public enum DocumentChange: Sendable {
    case moveNodes([NodeID: CGPoint])
    case setParam(NodeID, ParamID, ParamValue)
    case setTitle(NodeID, String?)
    case connect(from: SocketRef, to: SocketRef)
    case disconnect(SocketRef)
    case addNode(NodeInstance)
    case removeNodes(Set<NodeID>)
    /// Paste / duplicate: nodes first, then wires among them, as one change.
    case insert(nodes: [NodeInstance], edges: [Edge])
    case setSettings(DocumentSettings)
    /// Undo/redo only. Bypasses transactions; never registers an undo of its own.
    case restore(ShaderDocument)

    public var changeClass: ChangeClass {
        switch self {
        case .moveNodes, .setTitle: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNodes, .insert, .setSettings, .restore: .topology
        }
    }

    /// Edit-menu label for the undo step this change creates.
    public var undoName: String {
        switch self {
        case .moveNodes: "Move"
        case .setParam: "Change Value"
        case .setTitle: "Rename"
        case .connect: "Connect"
        case .disconnect: "Disconnect"
        case .addNode: "Add Node"
        case .removeNodes: "Delete"
        case .insert: "Paste"
        case .setSettings: "Change Settings"
        case .restore: "Restore"
        }
    }
}
```

- [ ] **Step 6: Replace `EditorModel.apply` (lines 53–82)**

```swift
    public func apply(_ change: DocumentChange) {
        switch change {
        case .moveNodes(let positions):
            for (id, p) in positions { document.root.nodes[id]?.position = p }
        case .setParam(let id, let key, let value):
            document.root.nodes[id]?.params[key] = value
        case .setTitle(let id, let title):
            document.root.nodes[id]?.customTitle = title.flatMap { $0.isEmpty ? nil : $0 }
        case .connect(let from, let to):
            document.root.connect(from, to: to)
        case .disconnect(let input):
            document.root.disconnect(input)
        case .addNode(let n):
            document.root.nodes[n.id] = n
        case .removeNodes(let ids):
            document.root.remove(nodes: ids)
            pruneSelection()
        case .insert(let nodes, let edges):
            for n in nodes { document.root.nodes[n.id] = n }
            for e in edges { document.root.connect(e.from, to: e.to) }
        case .setSettings(let s):
            document.settings = s
        case .restore(let doc):
            document = doc
            pruneSelection()
        }

        switch change.changeClass {
        case .cosmetic:
            break
        case .parameter:
            if case .setParam(let id, let key, let value) = change, var img = preview.uniforms {
                if !img.set(value, for: ParamPath(node: id, param: key)) {
                    scheduleCompile()
                }
                preview.uniforms = img
            }
        case .topology:
            scheduleCompile()
        }
    }

    /// Selection may only reference nodes that exist (spec §18.3).
    func pruneSelection() {
        viewState.selection = viewState.selection.filter { document.root.nodes[$0] != nil }
    }
```

- [ ] **Step 7: Fix the two call sites**

`NodeView.swift:51`: `onChange(.moveNode(node.id, to: …))` → `onChange(.moveNodes([node.id: CGPoint(x: o.x + g.translation.width, y: o.y + g.translation.height)]))`.

`EditorModelTests.swift`: in `classification`, replace the `moveNode` line with `#expect(DocumentChange.moveNodes([id: .zero]).changeClass == .cosmetic)` and the `removeNode` line with `#expect(DocumentChange.removeNodes([id]).changeClass == .topology)`; add `#expect(DocumentChange.setTitle(id, "x").changeClass == .cosmetic)` and `#expect(DocumentChange.insert(nodes: [], edges: []).changeClass == .topology)`. In `cosmeticChangeDoesNotCompile` use `.moveNodes([uv.id: CGPoint(x: 5, y: 5)])`. In `invalidGraphReportsDiagnosticsAndDoesNotCompile` use `.removeNodes([node(m, "output.fragment").id])`.

Add to `EditorModelTests`:

```swift
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
```

- [ ] **Step 8: Run the full suite**

Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'`
Expected: three green lines; no errors.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit
git commit -m "feat: public Edge, DocumentChange v2 (multi-move, remove set, insert, title, settings, restore)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 4: Undo — snapshot transactions

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (stored state + `apply` wrapper)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Undo.swift`
- Create: `MetalNodesKit/Tests/MetalNodesUITests/EditorUndoTests.swift`

**Interfaces:**
- Produces on `EditorModel`: `let undoManager: UndoManager` (`groupsByEvent = false`); `func beginTransaction(_ name: String)`; `func endTransaction()`; `func undo()`; `func redo()`; `var canUndo: Bool`; `var canRedo: Bool`; `var isInTransaction: Bool`.
- Semantics (spec §18.3): an `apply` outside a transaction is its own one-step transaction; inside one, changes accumulate into a single step registered when the **outermost** `endTransaction()` closes it (begin/end calls nest with a depth counter, so helpers like `duplicateSelection` can open their own transaction inside a gesture's); a transaction that leaves the document equal to its snapshot registers nothing; `.restore` never registers.

- [ ] **Step 1: Write the failing tests**

`EditorUndoTests.swift`:

```swift
import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorUndoTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func singleApplyIsOneUndoStep() {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv")
        m.apply(.moveNodes([uv.id: CGPoint(x: 99, y: 99)]))
        #expect(m.canUndo)
        #expect(m.undoManager.undoActionName == "Move")
        m.undo()
        #expect(m.document == original)
        #expect(m.canRedo)
        m.redo()
        #expect(m.document.root.nodes[uv.id]?.position == CGPoint(x: 99, y: 99))
    }

    @Test func transactionCoalescesAGesture() {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv")
        m.beginTransaction("Move")
        for i in 1...5 { m.apply(.moveNodes([uv.id: CGPoint(x: CGFloat(i) * 10, y: 0)])) }
        #expect(!m.canUndo)                       // nothing registered until the gesture ends
        m.endTransaction()
        #expect(m.canUndo)
        m.undo()
        #expect(m.document == original)
        #expect(!m.canUndo)                       // exactly one step
    }

    @Test func nestedBeginJoinsTheOpenTransactionUntilTheOutermostEnd() {
        let m = model()
        let uv = node(m, "input.uv")
        m.beginTransaction("Outer")
        m.beginTransaction("Inner")
        m.apply(.moveNodes([uv.id: CGPoint(x: 1, y: 1)]))
        m.endTransaction()                        // closes Inner only
        #expect(!m.canUndo)
        #expect(m.isInTransaction)
        m.endTransaction()                        // closes Outer → one step
        #expect(m.canUndo)
        #expect(m.undoManager.undoActionName == "Outer")
        m.endTransaction()                        // unbalanced extra end is ignored
        #expect(!m.isInTransaction)
    }

    @Test func noOpTransactionRegistersNothing() {
        let m = model()
        m.beginTransaction("Nothing")
        m.endTransaction()
        #expect(!m.canUndo)
    }

    @Test func everyChangeKindRoundTripsThroughUndo() async {
        let m = model()
        let original = m.document
        let uv = node(m, "input.uv"), out = node(m, "output.fragment"), speed = node(m, "input.float")
        let fresh = NodeInstance(kind: .builtin("input.time"))
        var settings = m.document.settings; settings.fastMath = false
        let changes: [DocumentChange] = [
            .moveNodes([uv.id: CGPoint(x: 5, y: 5)]),
            .setParam(speed.id, "value", .float(0.9)),
            .setTitle(uv.id, "Coords"),
            .disconnect(SocketRef(out.id, "color")),
            .addNode(fresh),
            .removeNodes([speed.id]),
            .insert(nodes: [NodeInstance(kind: .builtin("input.time"))], edges: []),
            .setSettings(settings),
        ]
        for change in changes {
            m.apply(change)
            #expect(m.document != original, "\(change.undoName) changed nothing")
            m.undo()
            #expect(m.document == original, "\(change.undoName) did not undo cleanly")
        }
    }

    @Test func undoPrunesSelectionAndSchedulesCompile() async {
        let c = RecordingCompiler()
        let m = EditorModel(document: .sample(), compiler: c)
        m.debounceInterval = .milliseconds(5)
        m.start(); await m.awaitIdle()
        let fresh = NodeInstance(kind: .builtin("input.time"))
        m.apply(.addNode(fresh))
        m.viewState.selection = [fresh.id]
        await m.awaitIdle()
        m.undo()
        await m.awaitIdle()
        #expect(m.viewState.selection.isEmpty)
        #expect(await c.generations.count == 3)   // start, addNode, undo
    }

    @Test func restoreNeverRegistersAnUndoStep() {
        let m = model()
        var doc = m.document
        doc.settings.fastMath = false
        m.apply(.restore(doc))
        #expect(!m.canUndo)
        #expect(m.document.settings.fastMath == false)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter EditorUndoTests 2>&1 | grep error: | head -3`
Expected: `no member 'canUndo'` / `beginTransaction`.

- [ ] **Step 3: Add stored state to `EditorModel`**

In `EditorModel.swift`, after `private var scheduleCount = 0` add:

```swift
    // MARK: Undo (spec §18.3) — see EditorModel+Undo.swift
    public let undoManager = UndoManager()
    var transactionSnapshot: ShaderDocument?
    var transactionName = ""
    var transactionDepth = 0
```

and at the end of `init`, add `undoManager.groupsByEvent = false` (each registration is wrapped in its own explicit group so tests and the app behave identically with or without a run loop).

Then wrap `apply`: rename the existing method body to `private func perform(_ change: DocumentChange)` (everything from the first `switch change {` through the classification `switch`), and add the public entry point above it:

```swift
    public func apply(_ change: DocumentChange) {
        if case .restore = change {             // undo/redo path: no transaction, no registration
            perform(change)
            return
        }
        if transactionSnapshot != nil {
            perform(change)
        } else {
            let before = document
            perform(change)
            commitUndo(before: before, name: change.undoName)
        }
    }
```

- [ ] **Step 4: Write `EditorModel+Undo.swift`**

```swift
import Foundation
import MetalNodesCore

/// Snapshot-based undo (spec §5, §18.3). A transaction captures the document once;
/// `endTransaction` registers a single undo step that restores that snapshot.
extension EditorModel {
    public var isInTransaction: Bool { transactionSnapshot != nil }
    public var canUndo: Bool { undoManager.canUndo }
    public var canRedo: Bool { undoManager.canRedo }

    /// Opens a transaction; a nested call joins the open one, keeps its name, and must be
    /// balanced by its own `endTransaction()`.
    public func beginTransaction(_ name: String) {
        transactionDepth += 1
        guard transactionSnapshot == nil else { return }
        transactionSnapshot = document
        transactionName = name
    }

    /// Closes one level; the outermost close registers the undo step.
    public func endTransaction() {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        guard transactionDepth == 0, let before = transactionSnapshot else { return }
        transactionSnapshot = nil
        commitUndo(before: before, name: transactionName)
    }

    public func undo() { undoManager.undo() }
    public func redo() { undoManager.redo() }

    /// Registers "go back to `before`". Registering again inside the undo handler is what
    /// gives `UndoManager` its redo step.
    func commitUndo(before: ShaderDocument, name: String) {
        guard before != document else { return }
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let current = model.document
                model.commitUndo(before: current, name: name)
                model.apply(.restore(before))
            }
        }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }
}
```

`MainActor.assumeIsolated` is correct here: `UndoManager` invokes handlers on the thread that called `undo()`/`redo()`, which is always the main actor in this app (menu commands and tests). If the compiler accepts the closure without it (the handler is invoked synchronously from a `@MainActor` context), keep it anyway — it documents the assumption.

- [ ] **Step 5: Run the undo tests, then the full suite**

Run: `swift test --package-path MetalNodesKit --filter EditorUndoTests 2>&1 | tail -3` → all 7 pass.
(`transactionCoalescesAGesture` asserts `!m.canUndo` after five applies inside the open transaction — that is what proves nothing registers early.)
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.

If `singleApplyIsOneUndoStep` fails on `undoActionName`, check that `setActionName` is called *inside* the open group (it is in the code above) — `UndoManager` attaches the name to the current group.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): snapshot undo transactions with gesture coalescing

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 5: Selection model and canvas geometry (pure)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeGeometry.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/CanvasTransform.swift` (add `fitting`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/WireLayer.swift` (add `WireGeometry.distance` and `point(t:)`)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Selection.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (add `selectedWire`)
- Create: `MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift`
- Create: `MetalNodesKit/Tests/MetalNodesUITests/EditorSelectionTests.swift`
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/CanvasTransformTests.swift`, `WireGeometryTests.swift` (one test each)

**Interfaces:**
- `enum NodeGeometry { static let width: CGFloat = 190; static let headerHeight: CGFloat = 26; static let rowHeight: CGFloat = 22; static let bodyPadding: CGFloat = 16; static func estimatedSize(for: NodeDef) -> CGSize; static func frame(for: NodeInstance, def: NodeDef) -> CGRect; static func nodes(in: Graph, intersecting: CGRect, registry: NodeRegistry) -> Set<NodeID>; static func bounds(of: some Collection<NodeID>, in: Graph, registry: NodeRegistry) -> CGRect? }`
- `CanvasTransform.fitting(_ rect: CGRect, in viewport: CGSize, padding: CGFloat = 40) -> CanvasTransform`
- `WireGeometry.point(t:from:to:) -> CGPoint`; `WireGeometry.distance(from p: CGPoint, wireFrom a: CGPoint, to b: CGPoint) -> CGFloat` (24 samples)
- `enum SelectionMode { replace, add, toggle }`; on `EditorModel`: `var selection: Set<NodeID>` (proxy to `viewState.selection`), `var selectedWire: SocketRef?` (transient), `func select(_: NodeID, mode:)`, `func select(nodes: Set<NodeID>, mode:)`, `func selectAll()`, `func clearSelection()`, `func deleteSelection()`, `func nudgeSelection(by: CGSize)`, `func frame(of: NodeID) -> CGRect?`, `var selectionBounds: CGRect?`, `var contentBounds: CGRect?`, `func node(at: CGPoint) -> NodeID?`.

- [ ] **Step 1: Write the failing tests**

`NodeGeometryTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct NodeGeometryTests {
    let reg = NodeRegistry.builtin

    @Test func estimatedSizeCountsRows() {
        let sep = reg["vector.separate"]!          // 1 input, 0 params, 3 outputs = 4 rows
        let s = NodeGeometry.estimatedSize(for: sep)
        #expect(s.width == 190)
        #expect(s.height == 26 + 16 + 4 * 22)
    }

    @Test func frameStartsAtPosition() {
        let n = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 100, y: 50))
        let f = NodeGeometry.frame(for: n, def: reg["input.uv"]!)
        #expect(f.origin == CGPoint(x: 100, y: 50))
        #expect(f.width == 190)
    }

    @Test func marqueeHitsIntersectingNodesOnly() {
        let doc = ShaderDocument.sample()      // uv at (0,0), time at (0,160), speed at (0,280) …
        let hit = NodeGeometry.nodes(in: doc.root, intersecting: CGRect(x: -10, y: -10, width: 50, height: 50), registry: reg)
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(hit == [uv.id])
        #expect(NodeGeometry.nodes(in: doc.root, intersecting: CGRect(x: 5000, y: 5000, width: 1, height: 1), registry: reg).isEmpty)
    }

    @Test func boundsUnionAllFrames() {
        let doc = ShaderDocument.sample()
        let all = NodeGeometry.bounds(of: doc.root.nodes.keys, in: doc.root, registry: reg)!
        #expect(all.minX == 0 && all.minY == 0)
        #expect(all.maxX == 1100 + 190)
        #expect(NodeGeometry.bounds(of: [NodeID](), in: doc.root, registry: reg) == nil)
    }
}
```

Append to `CanvasTransformTests`:

```swift
    @Test func fittingCentresTheRectAndClampsZoom() {
        let t = CanvasTransform.fitting(CGRect(x: 100, y: 100, width: 400, height: 200), in: CGSize(width: 1000, height: 600), padding: 40)
        #expect(abs(t.zoom - 2.3) < 1e-9)                       // width-limited: (1000-80)/400 = 2.3; height would allow 2.6
        let centre = t.toScreen(CGPoint(x: 300, y: 200))          // rect centre
        #expect(abs(centre.x - 500) < 1e-6 && abs(centre.y - 300) < 1e-6)
        let tiny = CanvasTransform.fitting(CGRect(x: 0, y: 0, width: 10, height: 10), in: CGSize(width: 1000, height: 1000))
        #expect(tiny.zoom == CanvasTransform.maxZoom)
    }
```

Append to `WireGeometryTests`:

```swift
    @Test func distanceIsZeroOnTheCurveAndGrowsAway() {
        let a = CGPoint(x: 0, y: 0), b = CGPoint(x: 300, y: 100)
        let mid = WireGeometry.point(t: 0.5, from: a, to: b)
        #expect(WireGeometry.distance(from: mid, wireFrom: a, to: b) < 1.0)
        #expect(WireGeometry.distance(from: CGPoint(x: 150, y: -200), wireFrom: a, to: b) > 100)
        #expect(WireGeometry.distance(from: a, wireFrom: a, to: b) == 0)
    }
```

`EditorSelectionTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorSelectionTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func selectModes() {
        let m = model()
        let a = node(m, "input.uv").id, b = node(m, "input.time").id
        m.select(a)
        #expect(m.selection == [a])
        m.select(b, mode: .add)
        #expect(m.selection == [a, b])
        m.select(a, mode: .toggle)
        #expect(m.selection == [b])
        m.select(a)
        #expect(m.selection == [a])
        m.selectAll()
        #expect(m.selection.count == 11)
        m.clearSelection()
        #expect(m.selection.isEmpty)
    }

    @Test func selectingANodeClearsAWireSelection() {
        let m = model()
        let out = node(m, "output.fragment").id
        m.selectedWire = SocketRef(out, "color")
        m.select(node(m, "input.uv").id)
        #expect(m.selectedWire == nil)
    }

    @Test func deleteSelectionRemovesNodesAsOneUndoStep() {
        let m = model()
        let original = m.document
        m.select(nodes: [node(m, "input.uv").id, node(m, "input.time").id], mode: .replace)
        m.deleteSelection()
        #expect(m.document.root.nodes.count == 9)
        #expect(m.selection.isEmpty)
        m.undo()
        #expect(m.document == original)
    }

    @Test func deleteSelectionRemovesASelectedWireInstead() {
        let m = model()
        let out = node(m, "output.fragment").id
        m.select(node(m, "input.uv").id)
        m.selectedWire = SocketRef(out, "color")
        m.deleteSelection()
        #expect(m.document.root.source(feeding: SocketRef(out, "color")) == nil)
        #expect(m.document.root.nodes.count == 11)
        #expect(m.selectedWire == nil)
    }

    @Test func nudgeMovesEverySelectedNodeInOneStep() {
        let m = model()
        let a = node(m, "input.uv").id, b = node(m, "input.time").id
        let pa = m.document.root.nodes[a]!.position, pb = m.document.root.nodes[b]!.position
        m.select(nodes: [a, b], mode: .replace)
        m.nudgeSelection(by: CGSize(width: 10, height: -10))
        #expect(m.document.root.nodes[a]!.position == CGPoint(x: pa.x + 10, y: pa.y - 10))
        #expect(m.document.root.nodes[b]!.position == CGPoint(x: pb.x + 10, y: pb.y - 10))
        m.undo()
        #expect(m.document.root.nodes[a]!.position == pa)
        #expect(!m.canUndo)
    }

    @Test func boundsAndHitTesting() {
        let m = model()
        let uv = node(m, "input.uv").id
        #expect(m.frame(of: uv)?.origin == .zero)
        #expect(m.node(at: CGPoint(x: 20, y: 20)) == uv)
        #expect(m.node(at: CGPoint(x: -5, y: -5)) == nil)
        m.select(uv)
        #expect(m.selectionBounds == m.frame(of: uv))
        #expect(m.contentBounds!.maxX == 1100 + 190)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter 'NodeGeometryTests|EditorSelectionTests' 2>&1 | grep error: | head -3`
Expected: `cannot find 'NodeGeometry'`, `no member 'select'`.

- [ ] **Step 3: Write `NodeGeometry.swift`**

```swift
import CoreGraphics
import MetalNodesCore

/// Node frames without measuring views: a fixed width and an estimated height from the
/// row count. Used for marquee hits, culling, zoom-to-fit and paste placement (spec §18.9).
enum NodeGeometry {
    static let width: CGFloat = 190
    static let headerHeight: CGFloat = 26
    static let rowHeight: CGFloat = 22
    static let bodyPadding: CGFloat = 16

    static func estimatedSize(for def: NodeDef) -> CGSize {
        let rows = def.inputs.count + def.params.count + def.outputs.count
        return CGSize(width: width, height: headerHeight + bodyPadding + CGFloat(rows) * rowHeight)
    }

    static func frame(for node: NodeInstance, def: NodeDef) -> CGRect {
        CGRect(origin: node.position, size: estimatedSize(for: def))
    }

    static func frame(for node: NodeInstance, registry: NodeRegistry) -> CGRect? {
        guard case .builtin(let id) = node.kind, let def = registry[id] else { return nil }
        return frame(for: node, def: def)
    }

    static func nodes(in graph: Graph, intersecting rect: CGRect, registry: NodeRegistry) -> Set<NodeID> {
        var out = Set<NodeID>()
        for n in graph.nodes.values {
            if let f = frame(for: n, registry: registry), f.intersects(rect) { out.insert(n.id) }
        }
        return out
    }

    static func bounds(of ids: some Collection<NodeID>, in graph: Graph, registry: NodeRegistry) -> CGRect? {
        var acc: CGRect?
        for id in ids {
            guard let n = graph.nodes[id], let f = frame(for: n, registry: registry) else { continue }
            acc = acc.map { $0.union(f) } ?? f
        }
        return acc
    }
}
```

- [ ] **Step 4: Add `fitting` to `CanvasTransform`**

```swift
    /// The transform that shows `rect` centred in `viewport` with `padding` on every side (spec §18.6).
    public static func fitting(_ rect: CGRect, in viewport: CGSize, padding: CGFloat = 40) -> CanvasTransform {
        let availW = max(1, viewport.width - 2 * padding)
        let availH = max(1, viewport.height - 2 * padding)
        let z = min(availW / max(rect.width, 1), availH / max(rect.height, 1))
        var t = CanvasTransform(pan: .zero, zoom: z)          // init clamps zoom
        t.pan = CGSize(width: (viewport.width - rect.width * t.zoom) / 2 - rect.minX * t.zoom,
                       height: (viewport.height - rect.height * t.zoom) / 2 - rect.minY * t.zoom)
        return t
    }
```

- [ ] **Step 5: Add curve sampling to `WireGeometry`**

Add inside `enum WireGeometry`:

```swift
    /// Point on the cubic at parameter `t`, using the same control points as `path`.
    static func point(t: CGFloat, from a: CGPoint, to b: CGPoint) -> CGPoint {
        let d = controlOffset(from: a, to: b)
        let c1 = CGPoint(x: a.x + d, y: a.y), c2 = CGPoint(x: b.x - d, y: b.y)
        let u = 1 - t
        let x = u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x
        let y = u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
        return CGPoint(x: x, y: y)
    }

    /// Distance from `p` to the wire, sampled at 24 points (spec §18.5).
    static func distance(from p: CGPoint, wireFrom a: CGPoint, to b: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        for i in 0...24 {
            let q = point(t: CGFloat(i) / 24, from: a, to: b)
            best = min(best, hypot(q.x - p.x, q.y - p.y))
        }
        return best
    }
```

- [ ] **Step 6: Add `selectedWire` to `EditorModel` and write `EditorModel+Selection.swift`**

In `EditorModel.swift`, after `public var viewState = EditorViewState()`, add:

```swift
    /// The one selected wire, by its input socket. Transient (not view state, not undo).
    public var selectedWire: SocketRef?
```

`EditorModel+Selection.swift`:

```swift
import CoreGraphics
import MetalNodesCore

public enum SelectionMode: Sendable { case replace, add, toggle }

/// Selection lives in `viewState` (persisted, never undone — spec §5, §18.2).
extension EditorModel {
    public var selection: Set<NodeID> {
        get { viewState.selection }
        set { viewState.selection = newValue }
    }

    public func select(_ id: NodeID, mode: SelectionMode = .replace) {
        select(nodes: [id], mode: mode)
    }

    public func select(nodes ids: Set<NodeID>, mode: SelectionMode) {
        selectedWire = nil
        switch mode {
        case .replace: selection = ids
        case .add: selection.formUnion(ids)
        case .toggle: selection.formSymmetricDifference(ids)
        }
        pruneSelection()
    }

    public func selectAll() { select(nodes: Set(document.root.nodes.keys), mode: .replace) }

    public func clearSelection() {
        selection = []
        selectedWire = nil
    }

    /// ⌫: a selected wire wins over selected nodes (spec §18.5).
    public func deleteSelection() {
        if let wire = selectedWire {
            selectedWire = nil
            apply(.disconnect(wire))
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection
        selection = []
        apply(.removeNodes(ids))
    }

    /// Arrow keys: one undo step for the whole selection.
    public func nudgeSelection(by delta: CGSize) {
        guard !selection.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for id in selection {
            guard let p = document.root.nodes[id]?.position else { continue }
            moves[id] = CGPoint(x: p.x + delta.width, y: p.y + delta.height)
        }
        beginTransaction("Move")
        apply(.moveNodes(moves))
        endTransaction()
    }

    public func frame(of id: NodeID) -> CGRect? {
        guard let n = document.root.nodes[id] else { return nil }
        return NodeGeometry.frame(for: n, registry: registry)
    }

    public var selectionBounds: CGRect? { NodeGeometry.bounds(of: selection, in: document.root, registry: registry) }
    public var contentBounds: CGRect? { NodeGeometry.bounds(of: document.root.nodes.keys, in: document.root, registry: registry) }

    /// Topmost node under a canvas point — "topmost" is the last in UUID order, matching the draw order Task 15 fixes.
    public func node(at point: CGPoint) -> NodeID? {
        document.root.nodes.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .last { NodeGeometry.frame(for: $0, registry: registry)?.contains(point) == true }?
            .id
    }
}
```

- [ ] **Step 7: Run the new tests, then the full suite**

Run: `swift test --package-path MetalNodesKit --filter 'NodeGeometryTests|EditorSelectionTests|CanvasTransformTests|WireGeometryTests' 2>&1 | tail -3` → all pass.
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): selection model, node geometry, zoom-to-fit and wire distance

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 6: Selection UI — outline, multi-drag, marquee, keyboard, wire selection

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/InputModifiers.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ParamControl.swift` (add `onEditing`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift` (replace file)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/WireLayer.swift` (`WireLayer` gains `selected`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (replace file)

**Interfaces:**
- `enum InputModifiers { static func selectionMode() -> SelectionMode; static var shiftHeld: Bool }` — reads `NSEvent.modifierFlags` on macOS, `.replace`/`false` elsewhere.
- `ParamControl(label:kind:value:onChange:onEditing:)` — `onEditing: ((Bool) -> Void)? = nil`, called `true` when a slider scrub begins and `false` when it ends.
- `NodeView(node:def:resolved:graph:isSelected:compact:onChange:onSelect:onDragBegan:onDrag:onDragEnded:onEditing:)` — `compact` is accepted now (always `false` until Task 15). The header drag reports **translation only**; the canvas moves every selected node.
- `WireLayer(graph:anchors:selected:color:)`.
- `GraphCanvasView` owns: `@State marquee: CGRect?`, `@State spaceHeld`, `@State dragOrigins: [NodeID: CGPoint]`, `@FocusState canvasFocused`, and installs `onKeyPress` handlers for ⌫, arrows (⇧ = 10 pt), Escape, space.

Behaviour (spec §11.2, §12, §18.6):
- Click a node → replace selection; ⇧-click → add; ⌘-click → toggle. Dragging an unselected node selects it first, then moves the whole selection in one `Move` transaction.
- Drag on empty canvas → marquee (⇧ adds); with space held → pan. Click on empty canvas → clear selection, unless within 6 canvas pt of a wire → select that wire.
- Selected node: 2 pt `foreground` outline + soft glow. Selected wire: `foreground`, 3.5 pt.

- [ ] **Step 1: `InputModifiers.swift`**

```swift
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Modifier keys at the moment a gesture starts. SwiftUI gestures don't expose them.
enum InputModifiers {
    static func selectionMode() -> SelectionMode {
        #if os(macOS)
        let f = NSEvent.modifierFlags
        if f.contains(.command) { return .toggle }
        if f.contains(.shift) { return .add }
        #endif
        return .replace
    }

    static var shiftHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.shift)
        #else
        false
        #endif
    }
}
```

- [ ] **Step 2: `ParamControl` — editing callbacks**

Add the stored property after `let onChange: (ParamValue) -> Void`:

```swift
    var onEditing: ((Bool) -> Void)? = nil
```

and change the float `Slider` to:

```swift
                Slider(value: Binding(get: { f }, set: { onChange(.float($0)) }), in: range ?? -10...10,
                       onEditingChanged: { onEditing?($0) })
                    .controlSize(.mini)
```

Steppers, toggles, pickers, color pickers and text fields commit per change; each is its own undo step, which is the right granularity for discrete controls.

- [ ] **Step 3: Replace `NodeView.swift`**

```swift
import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let def: NodeDef
    let resolved: ResolvedNode?
    let graph: Graph
    let isSelected: Bool
    var compact = false
    let onChange: (DocumentChange) -> Void
    let onSelect: (SelectionMode) -> Void
    let onDragBegan: () -> Void
    let onDrag: (CGSize) -> Void
    let onDragEnded: () -> Void
    let onEditing: (Bool) -> Void

    @State private var dragging = false
    @State private var wasSelectedAtStart = false
    static let width: CGFloat = NodeGeometry.width

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !compact {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(def.inputs, id: \.name) { inputRow($0) }
                    ForEach(def.params, id: \.name) { param in
                        ParamControl(label: param.label, kind: param.kind,
                                     value: node.params[param.name] ?? param.defaultValue,
                                     onChange: { onChange(.setParam(node.id, param.name, $0)) },
                                     onEditing: onEditing)
                    }
                    ForEach(def.outputs, id: \.name) { outputRow($0) }
                }
                .padding(8)
            }
        }
        .frame(width: Self.width)
        .background(DraculaToken.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(isSelected ? DraculaTheme.selection.color : DraculaToken.background.color, lineWidth: isSelected ? 2 : 1))
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 6, y: isSelected ? 0 : 3)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(InputModifiers.selectionMode()) }
    }

    private var header: some View {
        HStack {
            Text(node.customTitle ?? def.title).font(.caption.weight(.semibold))
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(DraculaToken.background.color)
        .background(DraculaTheme.token(for: def.category).color)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        wasSelectedAtStart = isSelected
                        let mode = InputModifiers.selectionMode()
                        if !isSelected || mode != .replace { onSelect(mode) }
                        onDragBegan()
                    }
                    onDrag(g.translation)
                }
                .onEnded { g in
                    dragging = false
                    onDragEnded()
                    // A click (no movement) on an already-selected node collapses the selection to it.
                    if abs(g.translation.width) < 1 && abs(g.translation.height) < 1,
                       wasSelectedAtStart, InputModifiers.selectionMode() == .replace {
                        onSelect(.replace)
                    }
                }
        )
    }

    private func inputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.inputTypes[decl.name] ?? concrete(decl.type)
        let wired = graph.inputs[ref] != nil
        return HStack(spacing: 6) {
            SocketView(type: type).socketAnchor(ref).offset(x: -8 - SocketView.size / 2)
            if !wired, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: coerced(node.params[decl.name] ?? dflt, to: type),
                             onChange: { onChange(.setParam(node.id, decl.name, $0)) },
                             onEditing: onEditing)
            } else {
                Text(decl.label).font(.caption)
            }
        }
    }

    private func outputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.outputTypes[decl.name] ?? concrete(decl.type)
        return HStack(spacing: 6) {
            Spacer()
            Text(decl.label).font(.caption)
            SocketView(type: type).socketAnchor(ref).offset(x: 8 + SocketView.size / 2)
        }
    }

    private func concrete(_ t: TypeRef) -> SocketType {
        if case .concrete(let c) = t { return c } else { return .float }
    }

    private func coerced(_ v: ParamValue, to type: SocketType) -> ParamValue {
        switch (v, type) {
        case (.float(let x), .float2): .float2(.init(x, x))
        case (.float(let x), .float3): .float3(.init(x, x, x))
        case (.float(let x), .float4), (.float(let x), .color): .float4(.init(x, x, x, 1))
        default: v
        }
    }
}
```

- [ ] **Step 4: `WireLayer` — selected wire**

Replace the `WireLayer` struct:

```swift
/// All wires in one `Canvas`, drawn beneath the nodes. The selected wire is drawn last, thicker, in `foreground`.
struct WireLayer: View {
    let graph: Graph
    let anchors: [SocketRef: CGPoint]
    var selected: SocketRef? = nil
    let color: (SocketRef) -> Color

    var body: some View {
        Canvas { ctx, _ in
            for (to, from) in graph.inputs where to != selected {
                guard let a = anchors[from], let b = anchors[to] else { continue }
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(color(from)), lineWidth: 2)
            }
            if let to = selected, let from = graph.inputs[to], let a = anchors[from], let b = anchors[to] {
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(DraculaTheme.selection.color), lineWidth: 3.5)
            }
        }
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 5: Replace `GraphCanvasView.swift`**

```swift
import SwiftUI
import MetalNodesCore

public struct GraphCanvasView: View {
    let model: EditorModel
    @State private var transform = CanvasTransform()
    @State private var anchors: [SocketRef: CGPoint] = [:]
    @State private var zoomOrigin: CGFloat?
    @State private var panOrigin: CGSize?
    @State private var marqueeStart: CGPoint?          // canvas coords
    @State private var marquee: CGRect?                // canvas coords
    @State private var spaceHeld = false
    @State private var dragOrigins: [NodeID: CGPoint] = [:]
    @FocusState private var canvasFocused: Bool

    static let contentSize: CGFloat = 4000
    static let wireHitDistance: CGFloat = 6

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        // See the M1 note: the GeometryReader keeps the 4000×4000 content from dictating the pane size.
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DraculaToken.background.color
                gridDots
                content
                    .frame(width: Self.contentSize, height: Self.contentSize, alignment: .topLeading)
                    .scaleEffect(transform.zoom, anchor: .topLeading)
                    .offset(transform.pan)
                marqueeOverlay
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .gesture(backgroundDrag)
            .simultaneousGesture(magnifyGesture)
            .focusable()
            .focusEffectDisabled()
            .focused($canvasFocused)
            .onKeyPress(.space, phases: [.down, .up]) { press in
                spaceHeld = press.phase == .down
                return .handled
            }
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { model.deleteSelection(); return .handled }
            .onKeyPress(.escape) { model.clearSelection(); return .handled }
            .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow]) { press in
                let step: CGFloat = press.modifiers.contains(.shift) ? 10 : 1
                let d: CGSize = switch press.key {
                case .upArrow: CGSize(width: 0, height: -step)
                case .downArrow: CGSize(width: 0, height: step)
                case .leftArrow: CGSize(width: -step, height: 0)
                default: CGSize(width: step, height: 0)
                }
                model.nudgeSelection(by: d)
                return .handled
            }
        }
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        .onAppear { if let cam = model.viewState.cameras[.root] { transform = CanvasTransform(camera: cam) } }
    }

    // MARK: Content

    private var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: model.document.root, anchors: anchors, selected: model.selectedWire) { from in
                if let t = model.resolvedTypes[from.node]?.outputTypes[from.socket] {
                    return DraculaTheme.token(for: t).color
                }
                return DraculaTheme.wireDefault.color
            }
            ForEach(Array(model.document.root.nodes.values), id: \.id) { node in
                if case .builtin(let defID) = node.kind, let def = model.registry[defID] {
                    NodeView(node: node, def: def, resolved: model.resolvedTypes[node.id],
                             graph: model.document.root,
                             isSelected: model.selection.contains(node.id),
                             onChange: { model.apply($0) },
                             onSelect: { mode in canvasFocused = true; model.select(node.id, mode: mode) },
                             onDragBegan: { beginNodeDrag() },
                             onDrag: { moveSelection(by: $0) },
                             onDragEnded: { endNodeDrag() },
                             onEditing: { editing in editing ? model.beginTransaction("Change Value") : model.endTransaction() })
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
        }
        .coordinateSpace(.named("canvas"))
    }

    private var marqueeOverlay: some View {
        Group {
            if let m = marquee {
                let o = transform.toScreen(m.origin)
                Rectangle()
                    .fill(DraculaTheme.selection.color.opacity(0.08))
                    .overlay(Rectangle().stroke(DraculaTheme.selection.color.opacity(0.8), lineWidth: 1))
                    .frame(width: m.width * transform.zoom, height: m.height * transform.zoom)
                    .offset(x: o.x, y: o.y)
            }
        }
        .allowsHitTesting(false)
    }

    private var gridDots: some View {
        Canvas { ctx, size in
            let spacing = 24 * transform.zoom
            guard spacing >= 8 else { return }
            let ox = transform.pan.width.truncatingRemainder(dividingBy: spacing)
            let oy = transform.pan.height.truncatingRemainder(dividingBy: spacing)
            var x = ox
            while x < size.width {
                var y = oy
                while y < size.height {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)), with: .color(DraculaTheme.canvasGrid))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Node drag (whole selection, one transaction)

    private func beginNodeDrag() {
        dragOrigins = [:]
        for id in model.selection {
            if let p = model.document.root.nodes[id]?.position { dragOrigins[id] = p }
        }
        model.beginTransaction("Move")
    }

    private func moveSelection(by t: CGSize) {
        guard !dragOrigins.isEmpty else { return }
        var moves: [NodeID: CGPoint] = [:]
        for (id, o) in dragOrigins { moves[id] = CGPoint(x: o.x + t.width, y: o.y + t.height) }
        model.apply(.moveNodes(moves))
    }

    private func endNodeDrag() {
        model.endTransaction()
        dragOrigins = [:]
    }

    // MARK: Background: marquee / pan / click

    private var backgroundDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                canvasFocused = true
                if spaceHeld {
                    if panOrigin == nil { panOrigin = transform.pan }
                    transform.pan = CGSize(width: panOrigin!.width + g.translation.width, height: panOrigin!.height + g.translation.height)
                    return
                }
                let p = transform.toCanvas(g.location)
                if marqueeStart == nil { marqueeStart = transform.toCanvas(g.startLocation) }
                let s = marqueeStart!
                marquee = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            }
            .onEnded { g in
                defer { panOrigin = nil; marqueeStart = nil; marquee = nil }
                if panOrigin != nil { model.viewState.cameras[.root] = transform.camera; return }
                let moved = abs(g.translation.width) >= 4 || abs(g.translation.height) >= 4
                if moved, let m = marquee {
                    let hit = NodeGeometry.nodes(in: model.document.root, intersecting: m, registry: model.registry)
                    model.select(nodes: hit, mode: InputModifiers.shiftHeld ? .add : .replace)
                } else {
                    click(at: transform.toCanvas(g.location))
                }
            }
    }

    private func click(at p: CGPoint) {
        var best: (SocketRef, CGFloat)?
        for (to, from) in model.document.root.inputs {
            guard let a = anchors[from], let b = anchors[to] else { continue }
            let d = WireGeometry.distance(from: p, wireFrom: a, to: b)
            if d <= Self.wireHitDistance / transform.zoom && (best == nil || d < best!.1) { best = (to, d) }
        }
        if let (wire, _) = best {
            model.selection = []
            model.selectedWire = wire
        } else {
            model.clearSelection()
        }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { g in
                if zoomOrigin == nil { zoomOrigin = transform.zoom }
                let target = zoomOrigin! * g.magnification
                transform.zoom(by: target / transform.zoom, around: g.startLocation)
            }
            .onEnded { _ in zoomOrigin = nil; model.viewState.cameras[.root] = transform.camera }
    }
}
```

Note the wire hit threshold divides by zoom because `anchors` and `p` are in canvas units while 6 pt is a screen distance.

- [ ] **Step 6: Build and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning' ; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'`
Expected: no errors or warnings; three green lines. If `onKeyPress(_:phases:action:)` or `KeyPress.modifiers` is unavailable, report the exact error rather than dropping the feature.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): selection outline, multi-node drag transactions, marquee, keyboard, wire selection

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 7: Drop resolution and node placement (pure)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/DropResolver.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Placement.swift`
- Create: `MetalNodesKit/Tests/MetalNodesUITests/DropResolverTests.swift`
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/EditorSelectionTests.swift` (add two tests)

**Interfaces:**
- `enum DropTarget: Equatable { case socket(SocketRef), node(NodeID), empty }`
- `enum DropResolver { static let snapRadius: CGFloat = 14; static func resolve(point: CGPoint, source: SocketRef, dragType: SocketType, anchors: [SocketRef: CGPoint], graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> DropTarget; static func inputType(of: SocketRef, graph:registry:resolved:) -> SocketType?; static func outputType(of: SocketRef, graph:registry:resolved:) -> SocketType?; static func firstCompatibleInput(on: NodeID, for: SocketType, graph:registry:resolved:) -> SocketRef?; static func compatible(_ from: SocketType, _ to: SocketType) -> Bool }`
- On `EditorModel`: `@discardableResult func addNode(defID: String, at: CGPoint, select: Bool = true) -> NodeID?`; `@discardableResult func connectIfCompatible(_ from: SocketRef, to: SocketRef) -> Bool`.

Order (spec §18.5): nearest **input** socket within `snapRadius` canvas points that accepts `dragType` and is not on the source node → `.socket`; else the node whose frame contains the point (not the source node) → `.node`; else `.empty`.

- [ ] **Step 1: Write the failing tests**

`DropResolverTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct DropResolverTests {
    let reg = NodeRegistry.builtin
    let doc = ShaderDocument.sample()
    func node(_ defID: String) -> NodeInstance { doc.root.nodes.values.first { $0.kind == .builtin(defID) }! }
    var resolved: [NodeID: ResolvedNode] { (try? ShaderGenerator.generate(doc))?.resolved ?? [:] }

    /// Anchors as if every input socket sat 20 pt right of its node's origin, one row per input.
    var anchors: [SocketRef: CGPoint] {
        var a: [SocketRef: CGPoint] = [:]
        for n in doc.root.nodes.values {
            guard case .builtin(let id) = n.kind, let def = reg[id] else { continue }
            for (i, d) in def.inputs.enumerated() {
                a[SocketRef(n.id, d.name)] = CGPoint(x: n.position.x, y: n.position.y + 30 + CGFloat(i) * 22)
            }
            for (i, d) in def.outputs.enumerated() {
                a[SocketRef(n.id, d.name)] = CGPoint(x: n.position.x + 190, y: n.position.y + 30 + CGFloat(i) * 22)
            }
        }
        return a
    }

    @Test func snapsToNearestCompatibleInputWithinRadius() {
        let uv = node("input.uv"), sep = node("vector.separate")
        let target = SocketRef(sep.id, "v")
        let p = CGPoint(x: anchors[target]!.x + 10, y: anchors[target]!.y - 8)   // ~12.8 pt away
        let r = DropResolver.resolve(point: p, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                     anchors: anchors, graph: doc.root, registry: reg, resolved: resolved)
        #expect(r == .socket(target))
    }

    @Test func ignoresIncompatibleAndOutputSockets() {
        let uv = node("input.uv"), out = node("output.fragment")
        // Texture never converts; only `output.fragment.color` is nearby and it can't take a texture.
        let p = anchors[SocketRef(out.id, "color")]!
        let r = DropResolver.resolve(point: p, source: SocketRef(uv.id, "uv"), dragType: .texture,
                                     anchors: anchors, graph: doc.root, registry: reg, resolved: resolved)
        #expect(r == .node(out.id))          // falls through to the body rule
        let ownOutput = anchors[SocketRef(uv.id, "uv")]!
        let r2 = DropResolver.resolve(point: ownOutput, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                      anchors: anchors, graph: doc.root, registry: reg, resolved: resolved)
        #expect(r2 == .empty)                // own node is excluded entirely
    }

    @Test func fallsBackToNodeBodyThenEmpty() {
        let uv = node("input.uv"), mix = node("math.mix")
        let inside = CGPoint(x: mix.position.x + 100, y: mix.position.y + 10)   // header, far from sockets
        let r = DropResolver.resolve(point: inside, source: SocketRef(uv.id, "uv"), dragType: .float2,
                                     anchors: anchors, graph: doc.root, registry: reg, resolved: resolved)
        #expect(r == .node(mix.id))
        let r2 = DropResolver.resolve(point: CGPoint(x: -500, y: -500), source: SocketRef(uv.id, "uv"), dragType: .float2,
                                      anchors: anchors, graph: doc.root, registry: reg, resolved: resolved)
        #expect(r2 == .empty)
    }

    @Test func firstCompatibleInputRespectsDeclarationOrder() {
        let mix = node("math.mix")
        let first = DropResolver.firstCompatibleInput(on: mix.id, for: .float, graph: doc.root, registry: reg, resolved: resolved)
        #expect(first == SocketRef(mix.id, "a"))
        let none = DropResolver.firstCompatibleInput(on: mix.id, for: .texture, graph: doc.root, registry: reg, resolved: resolved)
        #expect(none == nil)
    }
}
```

Append to `EditorSelectionTests`:

```swift
    @Test func addNodePlacesSelectsAndUndoes() {
        let m = model()
        let original = m.document
        let id = m.addNode(defID: "noise.value", at: CGPoint(x: 300, y: 300))!
        #expect(m.document.root.nodes[id]?.position == CGPoint(x: 300, y: 300))
        #expect(m.selection == [id])
        #expect(m.addNode(defID: "nope", at: .zero) == nil)
        m.undo()
        #expect(m.document == original)
    }

    @Test func connectIfCompatibleChecksTypesAndNodes() {
        let m = model()
        let uv = node(m, "input.uv"), comb = node(m, "vector.combine")
        #expect(m.connectIfCompatible(SocketRef(uv.id, "uv"), to: SocketRef(comb.id, "z")))      // float2 → float (average)
        #expect(m.document.root.source(feeding: SocketRef(comb.id, "z")) == SocketRef(uv.id, "uv"))
        let bogus = NodeInstance(kind: .builtin("input.uv"))
        #expect(m.connectIfCompatible(SocketRef(bogus.id, "uv"), to: SocketRef(comb.id, "x")) == false)  // unknown node
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter 'DropResolverTests|EditorSelectionTests' 2>&1 | grep error: | head -3`
Expected: `cannot find 'DropResolver'`, `no member 'addNode'`.

- [ ] **Step 3: Write `DropResolver.swift`**

```swift
import CoreGraphics
import MetalNodesCore

enum DropTarget: Equatable {
    case socket(SocketRef)
    case node(NodeID)
    case empty
}

/// Where a wire drag ends up (spec §18.5): socket → node body → empty canvas.
enum DropResolver {
    static let snapRadius: CGFloat = 14

    static func compatible(_ from: SocketType, _ to: SocketType) -> Bool {
        ConversionRules.convert(from: from, to: to) != nil
    }

    private static func def(of node: NodeID, graph: Graph, registry: NodeRegistry) -> NodeDef? {
        guard let n = graph.nodes[node], case .builtin(let id) = n.kind else { return nil }
        return registry[id]
    }

    static func inputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let d = def(of: ref.node, graph: graph, registry: registry), let decl = d.input(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.inputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    static func outputType(of ref: SocketRef, graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> SocketType? {
        guard let d = def(of: ref.node, graph: graph, registry: registry), let decl = d.output(named: ref.socket) else { return nil }
        if let t = resolved[ref.node]?.outputTypes[ref.socket] { return t }
        if case .concrete(let c) = decl.type { return c }
        return .float
    }

    static func firstCompatibleInput(on node: NodeID, for type: SocketType, graph: Graph, registry: NodeRegistry,
                                     resolved: [NodeID: ResolvedNode]) -> SocketRef? {
        guard let d = def(of: node, graph: graph, registry: registry) else { return nil }
        for decl in d.inputs {
            let ref = SocketRef(node, decl.name)
            if let t = inputType(of: ref, graph: graph, registry: registry, resolved: resolved), compatible(type, t) { return ref }
        }
        return nil
    }

    static func resolve(point: CGPoint, source: SocketRef, dragType: SocketType, anchors: [SocketRef: CGPoint],
                        graph: Graph, registry: NodeRegistry, resolved: [NodeID: ResolvedNode]) -> DropTarget {
        var best: (SocketRef, CGFloat)?
        for (ref, a) in anchors where ref.node != source.node {
            let d = hypot(a.x - point.x, a.y - point.y)
            guard d <= snapRadius, d < (best?.1 ?? .infinity) else { continue }
            guard let t = inputType(of: ref, graph: graph, registry: registry, resolved: resolved), compatible(dragType, t) else { continue }
            best = (ref, d)
        }
        if let (ref, _) = best { return .socket(ref) }

        for n in graph.nodes.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }).reversed()
        where n.id != source.node {
            if let f = NodeGeometry.frame(for: n, registry: registry), f.contains(point) { return .node(n.id) }
        }
        return .empty
    }
}
```

- [ ] **Step 4: Write `EditorModel+Placement.swift`**

```swift
import CoreGraphics
import MetalNodesCore

extension EditorModel {
    /// Adds a builtin node with its defaults at `point` (top-left) and selects it. `nil` for an unknown id.
    @discardableResult
    public func addNode(defID: String, at point: CGPoint, select: Bool = true) -> NodeID? {
        guard registry[defID] != nil else { return nil }
        let n = NodeInstance(kind: .builtin(defID), position: point)
        apply(.addNode(n))
        if select { self.select(n.id) }
        return n.id
    }

    /// Connects only if the resolved/declared types convert (spec §7.2). Returns whether it did.
    @discardableResult
    public func connectIfCompatible(_ from: SocketRef, to: SocketRef) -> Bool {
        guard let ft = DropResolver.outputType(of: from, graph: document.root, registry: registry, resolved: resolvedTypes),
              let tt = DropResolver.inputType(of: to, graph: document.root, registry: registry, resolved: resolvedTypes),
              DropResolver.compatible(ft, tt) else { return false }
        apply(.connect(from: from, to: to))
        return true
    }
}
```

- [ ] **Step 5: Run the tests, then the full suite**

Run: `swift test --package-path MetalNodesKit --filter 'DropResolverTests|EditorSelectionTests' 2>&1 | tail -3` → all pass.
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): wire drop resolution and node placement helpers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 8: Rubber-band wiring UI

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/SocketView.swift` (dimming + hit area)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift` (socket drag hooks, `dragType`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/WireLayer.swift` (pending wire)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (pending-wire state, drop handling)

**Interfaces:**
- `SocketView(type:dimmed:)` — 20×20 hit area around the 10 pt dot; `dimmed` renders at 30 % opacity.
- `NodeView` gains `dragType: SocketType?` (the type currently being dragged, for dimming) and `onSocketDragBegan: (SocketRef, Bool) -> Void` (`true` = input socket), `onSocketDrag: (CGPoint) -> Void`, `onSocketDragEnded: (CGPoint) -> Void` — all points in canvas coordinates.
- `struct PendingWire: Equatable { var source: SocketRef; var type: SocketType; var point: CGPoint }` (in `GraphCanvasView.swift`).
- `WireLayer(graph:anchors:selected:pending:color:)` draws the rubber band from `anchors[pending.source]` to `pending.point`.
- `GraphCanvasView` exposes `var onWireDroppedOnEmpty: ((SocketRef, SocketType, CGPoint) -> Void)?` (stored property, `nil` here; Task 11 wires it to the search popover).

Behaviour (spec §18.5): drag from an output starts a pending wire; drag from a **wired** input detaches it (one `Rewire` transaction spans detach + reconnect) and continues from the original source; drag from an unwired input does nothing. On release: `DropResolver.resolve` → `.socket` connects; `.node` connects to the first compatible input; `.empty` calls `onWireDroppedOnEmpty` (or just cancels). During a drag, inputs that can't accept the type and every output socket render dimmed.

- [ ] **Step 1: `SocketView` — dimming and a larger hit area**

Replace the `SocketView` struct (keep `SocketAnchorKey` and `socketAnchor`):

```swift
/// Circle for scalars/vectors, diamond for color, square for texture (spec §7.1).
/// The visible dot is 10 pt; the hit area is 20 pt so wires are easy to grab.
struct SocketView: View {
    let type: SocketType
    var dimmed = false
    static let size: CGFloat = 10
    static let hitSize: CGFloat = 20

    var body: some View {
        let fill = DraculaTheme.token(for: type).color
        Group {
            switch type {
            case .color:
                Rectangle().fill(fill).rotationEffect(.degrees(45)).scaleEffect(0.8)
            case .texture:
                Rectangle().fill(fill)
            default:
                Circle().fill(fill)
            }
        }
        .frame(width: Self.size, height: Self.size)
        .overlay {
            Group {
                switch type {
                case .color: Rectangle().stroke(DraculaToken.background.color, lineWidth: 1).rotationEffect(.degrees(45)).scaleEffect(0.8)
                case .texture: Rectangle().stroke(DraculaToken.background.color, lineWidth: 1)
                default: Circle().stroke(DraculaToken.background.color, lineWidth: 1)
                }
            }
        }
        .opacity(dimmed ? 0.3 : 1)
        .frame(width: Self.hitSize, height: Self.hitSize)
        .contentShape(Rectangle())
    }
}
```

Because the frame is now 20 pt, the `.offset(x:)` in `NodeView` rows changes from `±(8 + size/2)` to `±(8 + hitSize/2)` — see Step 2. `socketAnchor` still reports the centre, which is unchanged.

- [ ] **Step 2: `NodeView` — socket drags and dimming**

Add properties after `let onEditing: (Bool) -> Void`:

```swift
    var dragType: SocketType? = nil
    var onSocketDragBegan: (SocketRef, Bool) -> Void = { _, _ in }
    var onSocketDrag: (CGPoint) -> Void = { _ in }
    var onSocketDragEnded: (CGPoint) -> Void = { _ in }
```

Replace `inputRow` and `outputRow`:

```swift
    private func inputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.inputTypes[decl.name] ?? concrete(decl.type)
        let wired = graph.inputs[ref] != nil
        let dim = dragType.map { !DropResolver.compatible($0, type) } ?? false
        return HStack(spacing: 6) {
            SocketView(type: type, dimmed: dim)
                .socketAnchor(ref)
                .offset(x: -8 - SocketView.hitSize / 2)
                .gesture(socketDrag(ref, isInput: true))
            if !wired, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                             value: coerced(node.params[decl.name] ?? dflt, to: type),
                             onChange: { onChange(.setParam(node.id, decl.name, $0)) },
                             onEditing: onEditing)
            } else {
                Text(decl.label).font(.caption)
            }
        }
    }

    private func outputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.outputTypes[decl.name] ?? concrete(decl.type)
        return HStack(spacing: 6) {
            Spacer()
            Text(decl.label).font(.caption)
            SocketView(type: type, dimmed: dragType != nil)
                .socketAnchor(ref)
                .offset(x: 8 + SocketView.hitSize / 2)
                .gesture(socketDrag(ref, isInput: false))
        }
    }

    private func socketDrag(_ ref: SocketRef, isInput: Bool) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
            .onChanged { g in
                if !socketDragging {
                    socketDragging = true
                    onSocketDragBegan(ref, isInput)
                }
                onSocketDrag(g.location)
            }
            .onEnded { g in
                socketDragging = false
                onSocketDragEnded(g.location)
            }
    }
```

and add `@State private var socketDragging = false` next to the other `@State`s. The `socketAnchor` modifier must stay **before** `.offset` so the reported centre is the dot's final position (as in M1).

- [ ] **Step 3: `WireLayer` — pending wire**

Add `var pending: PendingWire? = nil` after `selected`, and inside the `Canvas` closure, after drawing the selected wire:

```swift
            if let p = pending, let a = anchors[p.source] {
                ctx.stroke(WireGeometry.path(from: a, to: p.point),
                           with: .color(DraculaTheme.token(for: p.type).color.opacity(0.85)), lineWidth: 2)
            }
```

- [ ] **Step 4: `GraphCanvasView` — pending-wire state and drop handling**

Add near the top of the file (outside the struct):

```swift
/// A wire being dragged: from `source` (always an output socket) to the cursor.
struct PendingWire: Equatable {
    var source: SocketRef
    var type: SocketType
    var point: CGPoint
}
```

Add to the struct's stored properties:

```swift
    @State private var pendingWire: PendingWire?
    /// Task 11 sets this to open the search popover with an auto-wire; `nil` just cancels.
    var onWireDroppedOnEmpty: ((SocketRef, SocketType, CGPoint) -> Void)? = nil
```

Pass the new arguments in `content`: `WireLayer(graph:…, anchors:…, selected: model.selectedWire, pending: pendingWire) { … }` and, in the `NodeView(...)` call, after `onEditing:`:

```swift
                             dragType: pendingWire?.type,
                             onSocketDragBegan: { ref, isInput in beginWire(from: ref, isInput: isInput) },
                             onSocketDrag: { p in pendingWire?.point = p },
                             onSocketDragEnded: { p in endWire(at: p) })
```

Add the two methods:

```swift
    // MARK: Wiring (spec §18.5)

    private func beginWire(from ref: SocketRef, isInput: Bool) {
        canvasFocused = true
        let g = model.document.root
        if isInput {
            // Re-drag: detach the existing wire and continue from its source, as one undo step.
            guard let source = g.source(feeding: ref) else { return }
            model.beginTransaction("Rewire")
            model.apply(.disconnect(ref))
            guard let t = DropResolver.outputType(of: source, graph: g, registry: model.registry, resolved: model.resolvedTypes) else {
                model.endTransaction(); return
            }
            pendingWire = PendingWire(source: source, type: t, point: anchors[ref] ?? .zero)
        } else {
            guard let t = DropResolver.outputType(of: ref, graph: g, registry: model.registry, resolved: model.resolvedTypes) else { return }
            model.beginTransaction("Connect")
            pendingWire = PendingWire(source: ref, type: t, point: anchors[ref] ?? .zero)
        }
    }

    private func endWire(at p: CGPoint) {
        guard let w = pendingWire else { return }
        pendingWire = nil
        defer { model.endTransaction() }
        switch DropResolver.resolve(point: p, source: w.source, dragType: w.type, anchors: anchors,
                                    graph: model.document.root, registry: model.registry, resolved: model.resolvedTypes) {
        case .socket(let input):
            model.connectIfCompatible(w.source, to: input)
        case .node(let id):
            if let input = DropResolver.firstCompatibleInput(on: id, for: w.type, graph: model.document.root,
                                                             registry: model.registry, resolved: model.resolvedTypes) {
                model.connectIfCompatible(w.source, to: input)
            }
        case .empty:
            onWireDroppedOnEmpty?(w.source, w.type, p)
        }
    }
```

Also add `.onKeyPress(.escape)` handling for a live drag: change the existing escape handler to `{ if pendingWire != nil { pendingWire = nil; model.endTransaction() } else { model.clearSelection() }; return .handled }`. A cancelled re-drag leaves the wire detached, which is what Blender does; ⌘Z restores it because the `Rewire` transaction captured the pre-detach snapshot.

- [ ] **Step 5: Build and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning' ; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'`
Expected: clean; three green lines.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): rubber-band wiring with re-drag, compatibility dimming and drop resolution

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 9: Input model — scroll wheel, zoom-to-fit, menu commands

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ScrollWheelCatcherMac.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (canvas requests)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (catcher, fit handling)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift` (focused value)
- Modify: `MetalNodes/MetalNodesApp.swift` (commands)
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/EditorSelectionTests.swift` (one test)

**Interfaces:**
- `enum CanvasRequest: Equatable { case fitAll, fitSelection }`; on `EditorModel`: `var canvasRequest: CanvasRequest?` (observable; the canvas consumes and clears it) and `func requestCanvas(_:)`.
- `ScrollWheelCatcher(onScroll: (CGSize, CGPoint, Bool, Bool) -> Void)` — macOS only; delta, location in the catcher's top-left-origin coordinates, ⌘ held, precise (trackpad) deltas.
- `EditorCommands: Commands` with `@FocusedValue(\.editorModel)`; `FocusedValues.editorModel`. Menu: Undo ⌘Z, Redo ⇧⌘Z, Delete ⌫, Select All ⌘A, View ▸ Zoom to Fit (Home), Zoom to Selection (F). Cut/Copy/Paste/Duplicate are added in Task 13.
- `EditorView` sets `.focusedSceneValue(\.editorModel, model)`; the app adds `.commands { EditorCommands() }`.

Scroll semantics (spec §11.2, §18.6): plain scroll pans by the delta (natural direction — the canvas follows the fingers); ⌘-scroll zooms around the cursor by `exp(delta.height × k)` with `k = 0.01` for precise deltas and `0.1` for wheel lines. If the zoom direction feels inverted in the manual check, flip the sign of `delta.height` in exactly one place (`zoomFactor(for:)`).

- [ ] **Step 1: Write the failing test**

Append to `EditorSelectionTests`:

```swift
    @Test func canvasRequestsAreObservableAndOneShot() {
        let m = model()
        #expect(m.canvasRequest == nil)
        m.requestCanvas(.fitSelection)
        #expect(m.canvasRequest == .fitSelection)
        m.canvasRequest = nil
        #expect(m.canvasRequest == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter EditorSelectionTests 2>&1 | grep error: | head -2`
Expected: `no member 'canvasRequest'`.

- [ ] **Step 3: `EditorModel` — canvas requests**

Add after `public var selectedWire: SocketRef?`:

```swift
    /// One-shot requests from menus/commands to the canvas view, which consumes and clears them.
    public var canvasRequest: CanvasRequest?
    public func requestCanvas(_ r: CanvasRequest) { canvasRequest = r }
```

and, at file scope in `EditorModel.swift`:

```swift
public enum CanvasRequest: Equatable, Sendable { case fitAll, fitSelection }
```

- [ ] **Step 4: `ScrollWheelCatcherMac.swift`**

```swift
#if os(macOS)
import SwiftUI
import AppKit

/// SwiftUI has no scroll-wheel modifier, and an overlay that hit-tests would swallow clicks.
/// This zero-visual view installs a local event monitor and forwards scroll events whose
/// location falls inside its bounds (spec §18.6). `isFlipped` makes coordinates top-left
/// origin, matching SwiftUI.
struct ScrollWheelCatcher: NSViewRepresentable {
    typealias Handler = (_ delta: CGSize, _ location: CGPoint, _ commandHeld: Bool, _ precise: Bool) -> Void
    let onScroll: Handler

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onScroll = onScroll
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.onScroll = onScroll }

    final class CatcherView: NSView {
        var onScroll: Handler = { _, _, _, _ in }
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }      // never intercept clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) ?? event }
            }
        }

        private func handle(_ e: NSEvent) -> NSEvent? {
            guard e.window === window else { return e }
            let p = convert(e.locationInWindow, from: nil)
            guard bounds.contains(p) else { return e }
            onScroll(CGSize(width: e.scrollingDeltaX, height: e.scrollingDeltaY), p,
                     e.modifierFlags.contains(.command), e.hasPreciseScrollingDeltas)
            return nil
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}
#endif
```

If the compiler rejects `MainActor.assumeIsolated` inside the monitor closure (it is `@Sendable`), keep it — the monitor runs on the main thread — and wrap `self` access as shown; if it complains about capturing a non-Sendable `self`, mark `CatcherView` `@unchecked Sendable` with a comment that it is only ever touched on the main thread.

- [ ] **Step 5: `GraphCanvasView` — catcher and fit requests**

Inside the `GeometryReader`'s `ZStack`, after `marqueeOverlay`, add:

```swift
                #if os(macOS)
                ScrollWheelCatcher { delta, location, cmd, precise in
                    if cmd {
                        transform.zoom(by: zoomFactor(for: delta, precise: precise), around: location)
                    } else {
                        transform.pan(by: delta)
                    }
                    model.viewState.cameras[.root] = transform.camera
                }
                #endif
```

Add to the outer chain (after `.onAppear { … }`):

```swift
        .onChange(of: model.canvasRequest) { _, req in
            guard let req else { return }
            defer { model.canvasRequest = nil }
            let rect: CGRect? = switch req {
            case .fitAll: model.contentBounds
            case .fitSelection: model.selectionBounds ?? model.contentBounds
            }
            guard let r = rect, viewport != .zero else { return }
            transform = CanvasTransform.fitting(r, in: viewport, padding: 40)
            model.viewState.cameras[.root] = transform.camera
        }
```

which needs the viewport size: add `@State private var viewport: CGSize = .zero` and, on the `GeometryReader`'s inner ZStack, `.onAppear { viewport = geo.size }.onChange(of: geo.size) { _, s in viewport = s }`. Add the helper:

```swift
    private func zoomFactor(for delta: CGSize, precise: Bool) -> CGFloat {
        exp(delta.height * (precise ? 0.01 : 0.1))
    }
```

- [ ] **Step 6: `EditorCommands.swift`**

```swift
import SwiftUI

public struct EditorModelKey: FocusedValueKey {
    public typealias Value = EditorModel
}

public extension FocusedValues {
    var editorModel: EditorModel? {
        get { self[EditorModelKey.self] }
        set { self[EditorModelKey.self] = newValue }
    }
}

/// Edit / View menu items routed to the focused editor (spec §18.6). Cut/Copy/Paste/Duplicate land in Task 13.
public struct EditorCommands: Commands {
    @FocusedValue(\.editorModel) private var model

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { model?.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(model?.canUndo ?? false))
            Button("Redo") { model?.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(model?.canRedo ?? false))
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Delete") { model?.deleteSelection() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled((model?.selection.isEmpty ?? true) && model?.selectedWire == nil)
            Button("Select All") { model?.selectAll() }
                .keyboardShortcut("a", modifiers: .command)
        }
        CommandMenu("View") {
            Button("Zoom to Fit") { model?.requestCanvas(.fitAll) }
                .keyboardShortcut(.home, modifiers: [])
            Button("Zoom to Selection") { model?.requestCanvas(.fitSelection) }
                .keyboardShortcut("f", modifiers: [])
        }
    }
}
```

- [ ] **Step 7: Wire the focused value and the app**

`EditorView.body`: add `.focusedSceneValue(\.editorModel, model)` after `.tint(...)`.

`MetalNodesApp.body`: after the `WindowGroup { … }` closure add `.commands { EditorCommands() }`.

- [ ] **Step 8: Build (package + app) and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning'; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'; xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'`
Expected: clean; three green lines; `** BUILD SUCCEEDED **`. Then `git checkout -- MetalNodes.xcodeproj/project.pbxproj; rm -rf MetalNodes.xcodeproj/xcshareddata` if xcodebuild touched them.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit MetalNodes/MetalNodesApp.swift
git commit -m "feat(ui): scroll-wheel pan/zoom, zoom-to-fit, Edit and View menu commands

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 10: Palette search and node-def transfer (pure)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Palette/PaletteSearch.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Palette/NodeDefTransfer.swift`
- Create: `MetalNodesKit/Tests/MetalNodesUITests/PaletteSearchTests.swift`

**Interfaces:**
- `enum PaletteSearch { static func filter(_ query: String, in defs: [NodeDef]) -> [NodeDef]; static func grouped(_ defs: [NodeDef]) -> [(category: NodeCategory, defs: [NodeDef])]; static func acceptsInput(of type: SocketType, _ def: NodeDef) -> Bool }`
  - Empty/whitespace query → all defs sorted by (category order, title). Otherwise case-insensitive: rank 0 = title has the query as a prefix, 1 = title contains it, 2 = id contains it; ties by title. Non-matches drop.
  - `grouped` follows `NodeCategory.allCases` order and omits empty categories.
  - `acceptsInput(of:)` — any declared input whose concrete type (or, for generics, any allowed type) converts from `type`.
- `struct NodeDefTransfer: Codable, Transferable, Sendable { let defID: String }` under `UTType.metalNodesNodeDef` (`com.maxburger.metalnodes.nodedef`).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct PaletteSearchTests {
    let all = NodeRegistry.builtin.all

    @Test func emptyQueryReturnsEverythingGroupedInCategoryOrder() {
        let r = PaletteSearch.filter("   ", in: all)
        #expect(r.count == all.count)
        #expect(r.first?.category == .input)
        let g = PaletteSearch.grouped(r)
        #expect(g.map(\.category) == [.input, .math, .vector, .noise, .output])   // no sdf/color/utility in M1's library
        #expect(g.allSatisfy { !$0.defs.isEmpty })
    }

    @Test func prefixBeatsContainsBeatsID() {
        let r = PaletteSearch.filter("mi", in: all).map(\.id)
        #expect(r.first == "math.mix")            // title "Mix" — prefix
        #expect(r.contains("math.smoothstep") == false)
    }

    @Test func idMatchesSurfaceLast() {
        let r = PaletteSearch.filter("vector", in: all).map(\.id)
        // No title contains "vector"; ids do — all three vector nodes, sorted by title.
        #expect(r == ["vector.combine", "vector.length", "vector.separate"])
    }

    @Test func caseInsensitive() {
        #expect(PaletteSearch.filter("VALUE NOISE", in: all).map(\.id) == ["noise.value"])
    }

    @Test func acceptsInputHonoursConversions() {
        let mix = NodeRegistry.builtin["math.mix"]!, uv = NodeRegistry.builtin["input.uv"]!, out = NodeRegistry.builtin["output.fragment"]!
        #expect(PaletteSearch.acceptsInput(of: .float2, mix))
        #expect(PaletteSearch.acceptsInput(of: .texture, mix) == false)
        #expect(PaletteSearch.acceptsInput(of: .float, uv) == false)        // no inputs at all
        #expect(PaletteSearch.acceptsInput(of: .float3, out))
    }

    @Test func transferRoundTripsAsJSON() throws {
        let t = NodeDefTransfer(defID: "noise.value")
        let data = try JSONEncoder().encode(t)
        #expect(try JSONDecoder().decode(NodeDefTransfer.self, from: data).defID == "noise.value")
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter PaletteSearchTests 2>&1 | grep error: | head -2`
Expected: `cannot find 'PaletteSearch'`.

- [ ] **Step 3: `PaletteSearch.swift`**

```swift
import Foundation
import MetalNodesCore

/// Search and grouping for the palette and the ⇧A popover (spec §18.7).
enum PaletteSearch {
    private static let order: [NodeCategory: Int] = Dictionary(uniqueKeysWithValues: NodeCategory.allCases.enumerated().map { ($1, $0) })

    static func filter(_ query: String, in defs: [NodeDef]) -> [NodeDef] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return defs.sorted { (order[$0.category]!, $0.title) < (order[$1.category]!, $1.title) }
        }
        func rank(_ d: NodeDef) -> Int? {
            let t = d.title.lowercased()
            if t.hasPrefix(q) { return 0 }
            if t.contains(q) { return 1 }
            if d.id.lowercased().contains(q) { return 2 }
            return nil
        }
        return defs.compactMap { d in rank(d).map { ($0, d) } }
            .sorted { ($0.0, $0.1.title) < ($1.0, $1.1.title) }
            .map(\.1)
    }

    static func grouped(_ defs: [NodeDef]) -> [(category: NodeCategory, defs: [NodeDef])] {
        NodeCategory.allCases.compactMap { c in
            let ds = defs.filter { $0.category == c }
            return ds.isEmpty ? nil : (c, ds)
        }
    }

    /// True if some input of `def` could accept a value of `type` (used to filter the wire-drop popover).
    static func acceptsInput(of type: SocketType, _ def: NodeDef) -> Bool {
        def.inputs.contains { decl in
            switch decl.type {
            case .concrete(let c): DropResolver.compatible(type, c)
            case .generic(let g): (def.generics[g] ?? []).contains { DropResolver.compatible(type, $0) }
            }
        }
    }
}
```

- [ ] **Step 4: `NodeDefTransfer.swift`**

```swift
import CoreTransferable
import UniformTypeIdentifiers

extension UTType {
    /// Drag payload from the palette to the canvas. Dynamic type; never leaves the app.
    static let metalNodesNodeDef = UTType(exportedAs: "com.maxburger.metalnodes.nodedef")
}

/// What a palette row drags: just the definition id.
struct NodeDefTransfer: Codable, Transferable, Sendable {
    let defID: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .metalNodesNodeDef)
    }
}
```

- [ ] **Step 5: Run the tests and the suite**

Run: `swift test --package-path MetalNodesKit --filter PaletteSearchTests 2>&1 | tail -2` → 6 pass.
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.

If `emptyQueryReturnsEverythingGroupedInCategoryOrder`'s category list differs because the builtin library changed since M1, update the expected array to whatever `NodeCategory.allCases.filter { c in all.contains { $0.category == c } }` yields and say so in the report — the assertion's point is ordering and non-empty groups, not the exact set.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): palette search ranking and node-def drag transfer

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 11: Palette sidebar, search popover, drag-in and auto-wire

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Palette/PaletteView.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Palette/NodeSearchPopover.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (`CanvasRequest.place`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (drop destination, popover, ⇧A, double-click, wire-drop)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift` (three panes)

**Interfaces:**
- `CanvasRequest` gains `case place(defID: String)` — add at the viewport centre (palette double-click).
- `public struct PaletteView: View { init(model: EditorModel) }` — 220 pt sidebar: search field, grouped list, "My Functions" (empty until M4). Rows are `.draggable(NodeDefTransfer)`; double-click places at the viewport centre.
- `struct NodeSearchPopover: View { init(defs: [NodeDef], onPick: (NodeDef) -> Void, onCancel: () -> Void) }` — search field + list, ↑/↓ moves the highlight, Return picks, Escape cancels.
- `GraphCanvasView`: `.dropDestination(for: NodeDefTransfer.self)` places the node so its header centre lands on the drop point; ⇧A or double-click on empty canvas opens the popover at the cursor; a wire dropped on empty canvas opens the popover **filtered to `PaletteSearch.acceptsInput(of:)`** and auto-wires the pick (one `Add Node` transaction). The Task 8 `onWireDroppedOnEmpty` closure is removed — the canvas handles it directly.

- [ ] **Step 1: `CanvasRequest.place`**

In `EditorModel.swift` change the enum to:

```swift
public enum CanvasRequest: Equatable, Sendable {
    case fitAll, fitSelection
    /// Add a builtin at the viewport centre (palette double-click).
    case place(defID: String)
}
```

- [ ] **Step 2: `PaletteView.swift`**

```swift
import SwiftUI
import MetalNodesCore

/// Left sidebar (spec §18.7): search, categorised list, drag-out, double-click to place.
public struct PaletteView: View {
    let model: EditorModel
    @State private var query = ""

    public init(model: EditorModel) { self.model = model }

    private var results: [NodeDef] { PaletteSearch.filter(query, in: model.registry.all) }

    public var body: some View {
        VStack(spacing: 0) {
            TextField("Search nodes", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(8)
            List {
                ForEach(PaletteSearch.grouped(results), id: \.category) { group in
                    Section(group.category.rawValue.capitalized) {
                        ForEach(group.defs, id: \.id) { row($0) }
                    }
                }
                Section("My Functions") {
                    Text("None yet").font(.caption).foregroundStyle(DraculaToken.muted.color)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(DraculaToken.background.color)
    }

    private func row(_ def: NodeDef) -> some View {
        HStack(spacing: 8) {
            Circle().fill(DraculaTheme.token(for: def.category).color).frame(width: 8, height: 8)
            Text(def.title).font(.callout)
            Spacer()
        }
        .contentShape(Rectangle())
        .draggable(NodeDefTransfer(defID: def.id))
        .onTapGesture(count: 2) { model.requestCanvas(.place(defID: def.id)) }
    }
}
```

- [ ] **Step 3: `NodeSearchPopover.swift`**

```swift
import SwiftUI
import MetalNodesCore

/// The ⇧A / double-click / wire-drop node chooser (spec §18.7).
struct NodeSearchPopover: View {
    let defs: [NodeDef]
    let onPick: (NodeDef) -> Void
    let onCancel: () -> Void

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var fieldFocused: Bool

    private var results: [NodeDef] { PaletteSearch.filter(query, in: defs) }

    var body: some View {
        VStack(spacing: 6) {
            TextField("Add node…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit { pick() }
                .onChange(of: query) { _, _ in highlighted = 0 }
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(results.enumerated()), id: \.element.id) { i, def in
                        HStack(spacing: 8) {
                            Circle().fill(DraculaTheme.token(for: def.category).color).frame(width: 8, height: 8)
                            Text(def.title)
                            Spacer()
                            Text(def.category.rawValue).font(.caption2).foregroundStyle(DraculaToken.muted.color)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                        .listRowBackground(i == highlighted ? DraculaToken.surface.color : Color.clear)
                        .onTapGesture { highlighted = i; pick() }
                        .id(i)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: highlighted) { _, h in proxy.scrollTo(h) }
            }
        }
        .padding(8)
        .frame(width: 280, height: 340)
        .background(DraculaToken.background.color)
        .onAppear { fieldFocused = true }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(results.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onKeyPress(.escape) { onCancel(); return .handled }
    }

    private func pick() {
        guard results.indices.contains(highlighted) else { return }
        onPick(results[highlighted])
    }
}
```

- [ ] **Step 4: `GraphCanvasView` — drop, popover, ⇧A, double-click, wire-drop**

Remove `var onWireDroppedOnEmpty…` and add the popover state:

```swift
    /// Why the chooser is open: where to place, and (for a wire drop) what to auto-wire.
    struct Chooser: Identifiable {
        let id = UUID()
        var canvasPoint: CGPoint
        var screenPoint: CGPoint
        var wire: (source: SocketRef, type: SocketType)?
    }
    @State private var chooser: Chooser?
    @State private var hoverLocation: CGPoint = .zero      // viewport coords, for ⇧A
```

On the inner `ZStack` (the one with `.gesture(backgroundDrag)`), add:

```swift
            .onContinuousHover { phase in if case .active(let p) = phase { hoverLocation = p } }
            .onTapGesture(count: 2) { p in openChooser(atScreen: p, wire: nil) }
            .onKeyPress(characters: .init(charactersIn: "aA")) { press in
                guard press.modifiers.contains(.shift) else { return .ignored }
                openChooser(atScreen: hoverLocation, wire: nil)
                return .handled
            }
            .dropDestination(for: NodeDefTransfer.self) { items, location in
                guard let t = items.first else { return false }
                let c = transform.toCanvas(location)
                model.addNode(defID: t.defID, at: CGPoint(x: c.x - NodeGeometry.width / 2, y: c.y - NodeGeometry.headerHeight / 2))
                return true
            }
            .popover(item: $chooser, attachmentAnchor: .rect(.rect(CGRect(origin: chooser?.screenPoint ?? .zero, size: CGSize(width: 1, height: 1)))), arrowEdge: .top) { c in
                let defs = c.wire.map { w in model.registry.all.filter { PaletteSearch.acceptsInput(of: w.type, $0) } } ?? model.registry.all
                NodeSearchPopover(defs: defs, onPick: { def in place(def, for: c) }, onCancel: { chooser = nil })
            }
```

`onTapGesture(count:perform:)` with a location parameter and `onKeyPress(characters:action:)` both exist on macOS 14+. If the double-tap's location closure form is unavailable, use `.onTapGesture(count: 2, coordinateSpace: .local) { p in … }`.

Add the helpers:

```swift
    private func openChooser(atScreen p: CGPoint, wire: (SocketRef, SocketType)?) {
        chooser = Chooser(canvasPoint: transform.toCanvas(p), screenPoint: p, wire: wire.map { (source: $0.0, type: $0.1) })
    }

    private func place(_ def: NodeDef, for c: Chooser) {
        chooser = nil
        model.beginTransaction("Add Node")
        defer { model.endTransaction() }
        guard let id = model.addNode(defID: def.id, at: c.canvasPoint) else { return }
        if let w = c.wire,
           let input = DropResolver.firstCompatibleInput(on: id, for: w.type, graph: model.document.root,
                                                         registry: model.registry, resolved: model.resolvedTypes) {
            model.connectIfCompatible(w.source, to: input)
        }
    }
```

In `endWire(at:)`, replace `onWireDroppedOnEmpty?(w.source, w.type, p)` with `openChooser(atScreen: transform.toScreen(p), wire: (w.source, w.type))`. Note the wire's `Connect`/`Rewire` transaction ends in `endWire`'s `defer` *before* the popover pick; the pick opens its own `Add Node` transaction — two undo steps (detach, then add+wire) for a re-drag onto empty canvas, which is acceptable and matches Blender.

Handle `.place` in the `onChange(of: model.canvasRequest)` switch:

```swift
            case .place(let defID):
                let centre = transform.toCanvas(CGPoint(x: viewport.width / 2, y: viewport.height / 2))
                model.addNode(defID: defID, at: CGPoint(x: centre.x - NodeGeometry.width / 2, y: centre.y - NodeGeometry.headerHeight / 2))
                return
```

(restructure the `let rect: CGRect? = switch …` so `.place` returns early before the fit logic).

- [ ] **Step 5: `EditorView` — three panes**

Replace `split`:

```swift
    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            PaletteView(model: model).frame(minWidth: 200, idealWidth: 220, maxWidth: 320)
            GraphCanvasView(model: model).frame(minWidth: 480)
            previewPane.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        HStack(spacing: 0) {
            PaletteView(model: model).frame(width: 220)
            GraphCanvasView(model: model)
            previewPane.frame(width: 420)
        }
        #endif
    }
```

- [ ] **Step 6: Build (package + app) and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning'; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'; xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'`
Expected: clean; green; `** BUILD SUCCEEDED **`. Revert any pbxproj/xcshareddata churn.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): palette sidebar, node search popover, drag-in and wire-drop auto-wire

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 12: `GraphClipboard` — extract and materialize subgraphs (Core)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Clipboard/GraphClipboard.swift`
- Create: `MetalNodesKit/Tests/MetalNodesCoreTests/GraphClipboardTests.swift`

**Interfaces:**
- `public struct GraphClipboard: Codable, Sendable, Equatable { static let currentFormatVersion = 1; var formatVersion: Int; var sourceOrigin: CGPoint; var nodes: [NodeInstance]; var edges: [Edge]; var stickies: [StickyNote]; var frames: [CommentFrame]; var definitions: [GroupDefinition]; init(nodes:edges:sourceOrigin:) }` — `sourceOrigin` is the bounding-box origin the nodes were extracted from (so a menu paste can land at +24,+24).
- `static func extract(_ ids: Set<NodeID>, from graph: Graph) -> GraphClipboard` — nodes sorted by UUID, positions made relative to the bounding-box origin (`min x`, `min y` of the node positions), `edges = graph.internalEdges(among: ids)`.
- `func materialize(at origin: CGPoint) -> (nodes: [NodeInstance], edges: [Edge])` — fresh `NodeID`s, edges rewritten through the ID map, positions offset by `origin`. Each call yields new IDs.
- `var size: CGSize` — extent of the relative positions (for centring a paste).

`stickies`/`frames`/`definitions` are carried but always empty in M2 (M4/M5 fill them — spec §6, §18.4).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GraphClipboardTests {
    /// a(10,20) → b(300,20), c(300,200) unconnected, plus an external node d fed by b.
    private func fixture() -> (Graph, a: NodeID, b: NodeID, c: NodeID, d: NodeID) {
        let a = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 10, y: 20))
        let b = NodeInstance(kind: .builtin("vector.separate"), position: CGPoint(x: 300, y: 20), params: ["k": .float(1)])
        let c = NodeInstance(kind: .builtin("input.time"), position: CGPoint(x: 300, y: 200))
        let d = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 600, y: 20))
        var g = Graph()
        for n in [a, b, c, d] { g.nodes[n.id] = n }
        g.connect(SocketRef(a.id, "uv"), to: SocketRef(b.id, "v"))
        g.connect(SocketRef(b.id, "x"), to: SocketRef(d.id, "color"))
        return (g, a.id, b.id, c.id, d.id)
    }

    @Test func extractKeepsInternalEdgesAndRelativePositions() {
        let (g, a, b, c, _) = fixture()
        let clip = GraphClipboard.extract([a, b, c], from: g)
        #expect(clip.nodes.count == 3)
        #expect(clip.edges.count == 1)                              // a→b only; b→d is external
        #expect(clip.edges.first?.to.socket == "v")
        let positions = Dictionary(uniqueKeysWithValues: clip.nodes.map { ($0.id, $0.position) })
        #expect(positions[a] == CGPoint(x: 0, y: 0))
        #expect(positions[b] == CGPoint(x: 290, y: 0))
        #expect(positions[c] == CGPoint(x: 290, y: 180))
        #expect(clip.size == CGSize(width: 290, height: 180))
        #expect(clip.sourceOrigin == CGPoint(x: 10, y: 20))
        #expect(clip.formatVersion == GraphClipboard.currentFormatVersion)
        #expect(clip.nodes.first { $0.id == b }?.params["k"] == .float(1))
    }

    @Test func extractOfNothingIsEmpty() {
        let (g, _, _, _, _) = fixture()
        let clip = GraphClipboard.extract([], from: g)
        #expect(clip.nodes.isEmpty && clip.edges.isEmpty)
        #expect(clip.size == .zero)
    }

    @Test func materializeRemapsIDsAndOffsets() {
        let (g, a, b, _, _) = fixture()
        let clip = GraphClipboard.extract([a, b], from: g)
        let (nodes, edges) = clip.materialize(at: CGPoint(x: 1000, y: 500))
        #expect(nodes.count == 2 && edges.count == 1)
        let ids = Set(nodes.map(\.id))
        #expect(ids.isDisjoint(with: [a, b]))                       // fresh IDs
        #expect(ids.contains(edges[0].to.node) && ids.contains(edges[0].from.node))
        let byKind = Dictionary(uniqueKeysWithValues: nodes.map { ($0.kind, $0.position) })
        #expect(byKind[.builtin("input.uv")] == CGPoint(x: 1000, y: 500))
        #expect(byKind[.builtin("vector.separate")] == CGPoint(x: 1290, y: 500))
        let again = clip.materialize(at: .zero)
        #expect(Set(again.nodes.map(\.id)).isDisjoint(with: ids))    // every call is fresh
    }

    @Test func roundTripsThroughJSON() throws {
        let (g, a, b, c, _) = fixture()
        let clip = GraphClipboard.extract([a, b, c], from: g)
        let data = try JSONEncoder().encode(clip)
        #expect(try JSONDecoder().decode(GraphClipboard.self, from: data) == clip)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter GraphClipboardTests 2>&1 | grep error: | head -2`
Expected: `cannot find 'GraphClipboard'`.

- [ ] **Step 3: `GraphClipboard.swift`**

```swift
import Foundation
import CoreGraphics

/// The pasteboard payload (spec §6, §18.4): a subgraph with positions relative to its own
/// bounding box, plus the definitions/comments it depends on (empty until M4/M5).
public struct GraphClipboard: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = GraphClipboard.currentFormatVersion
    /// Where the nodes came from (bounding-box origin), so a menu paste can offset from it.
    public var sourceOrigin: CGPoint
    public var nodes: [NodeInstance]
    public var edges: [Edge]
    public var stickies: [StickyNote] = []
    public var frames: [CommentFrame] = []
    public var definitions: [GroupDefinition] = []

    public init(nodes: [NodeInstance], edges: [Edge], sourceOrigin: CGPoint = .zero) {
        self.nodes = nodes
        self.edges = edges
        self.sourceOrigin = sourceOrigin
    }

    /// Extent of the relative node positions (top-left of each node; excludes node size).
    public var size: CGSize {
        guard !nodes.isEmpty else { return .zero }
        let xs = nodes.map(\.position.x), ys = nodes.map(\.position.y)
        return CGSize(width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    public static func extract(_ ids: Set<NodeID>, from graph: Graph) -> GraphClipboard {
        let picked = ids.compactMap { graph.nodes[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        guard !picked.isEmpty else { return GraphClipboard(nodes: [], edges: []) }
        let ox = picked.map(\.position.x).min()!, oy = picked.map(\.position.y).min()!
        let rel = picked.map { n -> NodeInstance in
            var m = n
            m.position = CGPoint(x: n.position.x - ox, y: n.position.y - oy)
            return m
        }
        return GraphClipboard(nodes: rel, edges: graph.internalEdges(among: ids), sourceOrigin: CGPoint(x: ox, y: oy))
    }

    /// Fresh IDs every call, so the same clipboard can be pasted repeatedly.
    public func materialize(at origin: CGPoint) -> (nodes: [NodeInstance], edges: [Edge]) {
        var map: [NodeID: NodeID] = [:]
        let fresh = nodes.map { n -> NodeInstance in
            let id = NodeID()
            map[n.id] = id
            return NodeInstance(id: id, kind: n.kind,
                                position: CGPoint(x: n.position.x + origin.x, y: n.position.y + origin.y),
                                params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        let wires = edges.compactMap { e -> Edge? in
            guard let to = map[e.to.node], let from = map[e.from.node] else { return nil }
            return Edge(to: SocketRef(to, e.to.socket), from: SocketRef(from, e.from.socket))
        }
        return (fresh, wires)
    }
}
```

- [ ] **Step 4: Run the tests and the suite**

Run: `swift test --package-path MetalNodesKit --filter GraphClipboardTests 2>&1 | tail -2` → 4 pass.
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): GraphClipboard extract/materialize with ID remapping

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 13: Pasteboard, copy / cut / paste / duplicate, ⌥-drag, Edit menu

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/Pasteboarding.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/SystemPasteboard.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Clipboard.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (`pasteboard` + init)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/InputModifiers.swift` (`optionHeld`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (⌥-drag)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorCommands.swift` (Cut/Copy/Paste/Duplicate)
- Create: `MetalNodesKit/Tests/MetalNodesUITests/EditorClipboardTests.swift`

**Interfaces:**
- `@MainActor public protocol Pasteboarding: AnyObject { func write(_ data: Data, type: String); func read(type: String) -> Data? }`; `public final class MemoryPasteboard: Pasteboarding` (dictionary-backed, for tests); `public final class SystemPasteboard: Pasteboarding` (`NSPasteboard.general` on macOS, `UIPasteboard.general` otherwise).
- `EditorModel.init(document:compiler:registry: = .builtin, preview: = PreviewState(), pasteboard: any Pasteboarding = SystemPasteboard())`; `public static let pasteboardType = "com.maxburger.metalnodes.graph"`; `public let pasteboard: any Pasteboarding`.
- On `EditorModel`: `var canCopy: Bool`; `var canPaste: Bool`; `func copySelection()`; `func cutSelection()`; `@discardableResult func paste(at point: CGPoint? = nil) -> Set<NodeID>` (nil → `sourceOrigin + (24, 24)`); `@discardableResult func duplicateSelection(offset: CGSize = CGSize(width: 24, height: 24)) -> Set<NodeID>` (never touches the system pasteboard; one `Duplicate` undo step).
- `InputModifiers.optionHeld: Bool`.
- ⌥-drag on a node header duplicates the selection in place and drags the copies (one `Duplicate` undo step, spec §11.2).
- Edit menu: the standard Cut ⌘X / Copy ⌘C / Paste ⌘V items route to the canvas via `onCutCommand`/`onCopyCommand`/`onPasteCommand`; Duplicate ⌘D is a custom item gated on `canvasHasFocus` and `canCopy`.

- [ ] **Step 1: Write the failing tests**

`EditorClipboardTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorClipboardTests {
    private func model(_ pb: any Pasteboarding = MemoryPasteboard()) -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler(), pasteboard: pb)
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) }!
    }

    @Test func copyWritesTheGraphTypeAndPasteInsertsFreshNodes() throws {
        let pb = MemoryPasteboard()
        let m = model(pb)
        let uv = node(m, "input.uv"), sep = node(m, "vector.separate")     // uv → sep.v is an internal edge
        #expect(!m.canCopy && !m.canPaste)
        m.select(nodes: [uv.id, sep.id], mode: .replace)
        #expect(m.canCopy)
        m.copySelection()
        #expect(m.canPaste)
        let data = try #require(pb.read(type: EditorModel.pasteboardType))
        let clip = try JSONDecoder().decode(GraphClipboard.self, from: data)
        #expect(clip.nodes.count == 2 && clip.edges.count == 1)

        let before = m.document.root.nodes.count
        let pasted = m.paste(at: CGPoint(x: 2000, y: 2000))
        #expect(pasted.count == 2)
        #expect(m.document.root.nodes.count == before + 2)
        #expect(m.selection == pasted)
        #expect(pasted.isDisjoint(with: [uv.id, sep.id]))
        let newSep = pasted.first { m.document.root.nodes[$0]?.kind == .builtin("vector.separate") }!
        #expect(m.document.root.source(feeding: SocketRef(newSep, "v"))?.node != uv.id)   // wired to the *copied* uv
        #expect(m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") && $0.id != uv.id }?.position == CGPoint(x: 2000, y: 2000))
    }

    @Test func pasteIsOneUndoStep() {
        let m = model()
        let original = m.document
        m.select(node(m, "input.uv").id)
        m.copySelection()
        m.paste()
        #expect(m.document.root.nodes.count == 12)
        m.undo()
        #expect(m.document == original)
    }

    @Test func menuPasteOffsetsFromTheSourceOrigin() {
        let m = model()
        let time = node(m, "input.time")                                   // at (0, 160)
        m.select(time.id)
        m.copySelection()
        let pasted = m.paste()
        #expect(m.document.root.nodes[pasted.first!]?.position == CGPoint(x: 24, y: 184))
    }

    @Test func cutCopiesThenDeletes() {
        let m = model()
        let uv = node(m, "input.uv")
        m.select(uv.id)
        m.cutSelection()
        #expect(m.document.root.nodes[uv.id] == nil)
        #expect(m.canPaste)
        let pasted = m.paste(at: .zero)
        #expect(pasted.count == 1)
    }

    @Test func duplicateNeverTouchesThePasteboardAndUndoesAsOne() {
        let pb = MemoryPasteboard()
        let m = model(pb)
        let original = m.document
        let uv = node(m, "input.uv")
        m.select(uv.id)
        let dup = m.duplicateSelection()
        #expect(dup.count == 1)
        #expect(pb.read(type: EditorModel.pasteboardType) == nil)
        #expect(m.document.root.nodes[dup.first!]?.position == CGPoint(x: 24, y: 24))
        #expect(m.selection == dup)
        m.undo()
        #expect(m.document == original)
    }

    @Test func crossDocumentPasteThroughASharedPasteboard() {
        let pb = MemoryPasteboard()
        let a = model(pb), b = model(pb)
        a.select(node(a, "noise.value").id)
        a.copySelection()
        let pasted = b.paste(at: .zero)
        #expect(pasted.count == 1)
        #expect(b.document.root.nodes.count == 12)
    }

    @Test func garbageOnThePasteboardIsANoOp() {
        let pb = MemoryPasteboard()
        pb.write(Data("not json".utf8), type: EditorModel.pasteboardType)
        let m = model(pb)
        #expect(m.paste().isEmpty)
        #expect(m.document.root.nodes.count == 11)
        #expect(!m.canUndo)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter EditorClipboardTests 2>&1 | grep error: | head -2`
Expected: `cannot find 'MemoryPasteboard'`.

- [ ] **Step 3: `Pasteboarding.swift`**

```swift
import Foundation

/// The system pasteboard behind a protocol so paste is testable in memory (spec §18.4).
@MainActor
public protocol Pasteboarding: AnyObject {
    func write(_ data: Data, type: String)
    func read(type: String) -> Data?
}

@MainActor
public final class MemoryPasteboard: Pasteboarding {
    private var items: [String: Data] = [:]
    public init() {}
    public func write(_ data: Data, type: String) { items = [type: data] }
    public func read(type: String) -> Data? { items[type] }
}
```

- [ ] **Step 4: `SystemPasteboard.swift`**

```swift
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
public final class SystemPasteboard: Pasteboarding {
    public init() {}

    public func write(_ data: Data, type: String) {
        #if os(macOS)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(data, forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.setData(data, forPasteboardType: type)
        #endif
    }

    public func read(type: String) -> Data? {
        #if os(macOS)
        NSPasteboard.general.data(forType: NSPasteboard.PasteboardType(type))
        #else
        UIPasteboard.general.data(forPasteboardType: type)
        #endif
    }
}
```

- [ ] **Step 5: `EditorModel` — pasteboard**

Add `public static let pasteboardType = "com.maxburger.metalnodes.graph"` and `public let pasteboard: any Pasteboarding` to the class; extend `init` with `pasteboard: any Pasteboarding = SystemPasteboard()` as the last parameter and assign it.

- [ ] **Step 6: `EditorModel+Clipboard.swift`**

```swift
import Foundation
import CoreGraphics
import MetalNodesCore

extension EditorModel {
    public var canCopy: Bool { !selection.isEmpty }
    public var canPaste: Bool { pasteboard.read(type: Self.pasteboardType) != nil }

    public func copySelection() {
        guard canCopy else { return }
        let clip = GraphClipboard.extract(selection, from: document.root)
        if let data = try? JSONEncoder().encode(clip) {
            pasteboard.write(data, type: Self.pasteboardType)
        }
    }

    public func cutSelection() {
        guard canCopy else { return }
        copySelection()
        deleteSelection()
    }

    /// Pastes as one `Paste` step at `point` (bounding-box origin), or +24,+24 from where it was copied.
    @discardableResult
    public func paste(at point: CGPoint? = nil) -> Set<NodeID> {
        guard let data = pasteboard.read(type: Self.pasteboardType),
              let clip = try? JSONDecoder().decode(GraphClipboard.self, from: data),
              clip.formatVersion <= GraphClipboard.currentFormatVersion, !clip.nodes.isEmpty else { return [] }
        let origin = point ?? CGPoint(x: clip.sourceOrigin.x + 24, y: clip.sourceOrigin.y + 24)
        return insert(clip, at: origin, undoName: "Paste")
    }

    /// Copy + paste without the pasteboard; one `Duplicate` step.
    @discardableResult
    public func duplicateSelection(offset: CGSize = CGSize(width: 24, height: 24)) -> Set<NodeID> {
        guard canCopy else { return [] }
        let clip = GraphClipboard.extract(selection, from: document.root)
        let origin = CGPoint(x: clip.sourceOrigin.x + offset.width, y: clip.sourceOrigin.y + offset.height)
        return insert(clip, at: origin, undoName: "Duplicate")
    }

    private func insert(_ clip: GraphClipboard, at origin: CGPoint, undoName: String) -> Set<NodeID> {
        let (nodes, edges) = clip.materialize(at: origin)
        let ids = Set(nodes.map(\.id))
        beginTransaction(undoName)
        apply(.insert(nodes: nodes, edges: edges))
        endTransaction()
        select(nodes: ids, mode: .replace)
        return ids
    }
}
```

- [ ] **Step 7: ⌥-drag and the menu**

`InputModifiers.swift` — add:

```swift
    static var optionHeld: Bool {
        #if os(macOS)
        NSEvent.modifierFlags.contains(.option)
        #else
        false
        #endif
    }
```

`GraphCanvasView.beginNodeDrag()` — replace the whole method so the gesture opens exactly one transaction (transactions nest by depth, so `duplicateSelection`'s own begin/end pair stays inside it):

```swift
    private func beginNodeDrag() {
        let duplicating = InputModifiers.optionHeld && !model.selection.isEmpty
        model.beginTransaction(duplicating ? "Duplicate" : "Move")
        if duplicating { model.duplicateSelection(offset: .zero) }   // selection is now the copies, in place
        dragOrigins = [:]
        for id in model.selection {
            if let p = model.document.root.nodes[id]?.position { dragOrigins[id] = p }
        }
    }
```

(`endNodeDrag` still calls `endTransaction()` once, which now closes the outer transaction and registers a single `Duplicate` or `Move` step.)

`EditorCommands.swift` — the standard Cut/Copy/Paste/Select All items stay (controller ruling in Task 9: replacing the `.pasteboard` group breaks text-field editing). Add only Duplicate to the `CommandGroup(after: .pasteboard)` block, before `Delete`:

```swift
            Button("Duplicate") { model?.duplicateSelection() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(!(model?.canvasHasFocus ?? false) || !(model?.canCopy ?? false))
```

`GraphCanvasView.swift` — route the standard responder-chain commands to the model, next to the existing `.onDeleteCommand` / `.onCommand(#selector(NSResponder.selectAll(_:)))` modifiers (inside the same `#if os(macOS)` block):

```swift
            .onCutCommand { model.cutSelection(); return [] }
            .onCopyCommand { model.copySelection(); return [] }
            .onPasteCommand(of: [UTType(EditorModel.pasteboardType) ?? .data]) { _ in model.paste() }
```

(`import UniformTypeIdentifiers` at the top of the file.) `onCutCommand`/`onCopyCommand` return `[NSItemProvider]`; returning `[]` is correct because `copySelection()` already wrote the pasteboard through `Pasteboarding`. `onPasteCommand(of:)` enables the standard Paste item only when the pasteboard holds our type — `canPaste` is thereby honoured by AppKit.

- [ ] **Step 8: Run the tests, the suite, and the app build**

Run: `swift test --package-path MetalNodesKit --filter EditorClipboardTests 2>&1 | tail -2` → 7 pass.
Run: `swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'` → three green lines.
Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'` → `** BUILD SUCCEEDED **`; revert pbxproj/xcshareddata churn.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): pasteboard copy/cut/paste/duplicate, option-drag duplicate, Edit menu

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 14: Inspector

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift` (right pane = preview + inspector)

**Interfaces:**
- `public struct InspectorView: View { init(model: EditorModel) }` — spec §18.8:
  - one node selected: title field (commits on submit / focus loss as `setTitle`), definition id, category chip; each parameter and **unwired** input as a full-width `ParamControl` (with `onEditing` transactions); wired inputs listed as `← <Source title>.<socket>`; that node's diagnostics.
  - nothing selected: `DocumentSettings` — preview size (two integer fields), time mode picker, fast-math toggle — each committing `setSettings`.
  - several selected: "N nodes selected".

- [ ] **Step 1: `InspectorView.swift`**

```swift
import SwiftUI
import MetalNodesCore

/// Right sidebar (spec §18.8). Reuses `ParamControl`; the node body keeps its compact controls.
public struct InspectorView: View {
    let model: EditorModel
    @State private var titleDraft = ""

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch model.selection.count {
                case 0: documentSettings
                case 1: nodePane(model.selection.first!)
                default: Text("\(model.selection.count) nodes selected").font(.callout).foregroundStyle(DraculaToken.muted.color)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DraculaToken.background.color)
    }

    // MARK: Node

    @ViewBuilder
    private func nodePane(_ id: NodeID) -> some View {
        if let node = model.document.root.nodes[id], case .builtin(let defID) = node.kind, let def = model.registry[defID] {
            let resolved = model.resolvedTypes[id]
            HStack {
                Text(node.customTitle ?? def.title).font(.headline)
                Spacer()
                Text(def.category.rawValue.capitalized).font(.caption2)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(DraculaTheme.token(for: def.category).color.opacity(0.25))
                    .clipShape(Capsule())
            }
            Text(def.id).font(.caption.monospaced()).foregroundStyle(DraculaToken.muted.color)

            TextField("Title", text: $titleDraft, prompt: Text(def.title))
                .textFieldStyle(.roundedBorder)
                .onAppear { titleDraft = node.customTitle ?? "" }
                .onChange(of: id) { _, _ in titleDraft = node.customTitle ?? "" }
                .onSubmit { model.apply(.setTitle(id, titleDraft)) }

            Divider()

            ForEach(def.inputs, id: \.name) { decl in
                let ref = SocketRef(id, decl.name)
                if let src = model.document.root.source(feeding: ref) {
                    HStack {
                        Text(decl.label).font(.caption)
                        Spacer()
                        Text("← \(sourceLabel(src))").font(.caption).foregroundStyle(DraculaToken.muted.color)
                    }
                } else if case .value(let dflt) = decl.default {
                    let type = resolved?.inputTypes[decl.name] ?? (decl.type.concreteOrFloat)
                    ParamControl(label: decl.label, kind: .value(type, range: decl.range),
                                 value: node.params[decl.name] ?? dflt,
                                 onChange: { model.apply(.setParam(id, decl.name, $0)) },
                                 onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
                }
            }
            ForEach(def.params, id: \.name) { p in
                ParamControl(label: p.label, kind: p.kind, value: node.params[p.name] ?? p.defaultValue,
                             onChange: { model.apply(.setParam(id, p.name, $0)) },
                             onEditing: { $0 ? model.beginTransaction("Change Value") : model.endTransaction() })
            }

            let diags = model.diagnostics.filter { $0.node == id }
            if !diags.isEmpty {
                Divider()
                ForEach(Array(diags.enumerated()), id: \.offset) { _, d in
                    Text(d.message).font(.caption)
                        .foregroundStyle(d.severity == .error ? DraculaTheme.error.color : DraculaToken.orange.color)
                }
            }
        } else {
            Text("Unknown node").foregroundStyle(DraculaToken.muted.color)
        }
    }

    private func sourceLabel(_ src: SocketRef) -> String {
        guard let n = model.document.root.nodes[src.node], case .builtin(let d) = n.kind else { return src.socket }
        return "\(n.customTitle ?? model.registry[d]?.title ?? d).\(src.socket)"
    }

    // MARK: Document

    private var documentSettings: some View {
        let s = model.document.settings
        return VStack(alignment: .leading, spacing: 10) {
            Text("Document").font(.headline)
            HStack {
                Text("Preview size").font(.caption)
                TextField("W", value: Binding(get: { Int(s.previewSize.width) }, set: { w in
                    var n = s; n.previewSize.width = CGFloat(max(16, w)); model.apply(.setSettings(n)) }), format: .number)
                    .frame(width: 60)
                Text("×")
                TextField("H", value: Binding(get: { Int(s.previewSize.height) }, set: { h in
                    var n = s; n.previewSize.height = CGFloat(max(16, h)); model.apply(.setSettings(n)) }), format: .number)
                    .frame(width: 60)
            }
            Picker("Time", selection: Binding(get: { s.timeMode }, set: { m in var n = s; n.timeMode = m; model.apply(.setSettings(n)) })) {
                Text("Wall clock").tag(TimeMode.wallClock)
                Text("Fixed rate").tag(TimeMode.fixedRate)
            }
            .pickerStyle(.segmented)
            Toggle("Fast math", isOn: Binding(get: { s.fastMath }, set: { f in var n = s; n.fastMath = f; model.apply(.setSettings(n)) }))
                .toggleStyle(.switch)
            Text("Fast math relaxes NaN/Inf handling for speed. Off keeps IEEE semantics; changing it recompiles.")
                .font(.caption2).foregroundStyle(DraculaToken.muted.color)
        }
        .textFieldStyle(.roundedBorder)
    }
}

private extension TypeRef {
    var concreteOrFloat: SocketType {
        if case .concrete(let c) = self { return c } else { return .float }
    }
}
```

- [ ] **Step 2: `EditorView` — right pane**

Replace `previewPane`'s outer `VStack` so the inspector fills the rest:

```swift
    private var previewPane: some View {
        VStack(spacing: 8) {
            PreviewView(state: model.preview, device: device)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(DraculaToken.surface.color))
            HStack {
                Button(model.preview.isPlaying ? "Pause" : "Play") { model.preview.isPlaying.toggle() }
                Button("Reset") { model.preview.resetRequested = true }
                Spacer()
                Text("gen \(model.preview.pipeline?.generation ?? 0)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(DraculaToken.muted.color)
            }
            .controlSize(.small)
            diagnosticsList
            Divider()
            InspectorView(model: model)
        }
        .padding(10)
    }
```

- [ ] **Step 3: Build (package + app) and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning'; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'; xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'`
Expected: clean; green; `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): inspector — node params, rename, wired-input labels, document settings

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 15: Culling and LOD

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift` (`content`)
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift` (`compact` header sockets)
- Modify: `MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift` (one test)

**Interfaces:**
- `GraphCanvasView` renders only nodes whose estimated frame intersects `transform.visibleRect(viewport:)` insetted by `-200` (spec §18.9), sorted by UUID so z-order is stable (closes an M1 deferred minor). Wires always draw.
- `NodeView(compact: true)` below zoom `0.4`: header only, with every socket still anchored (so wires keep their endpoints) but no controls. `static let lodZoom: CGFloat = 0.4`.
- `NodeGeometry.visibleNodes(in:transform:viewport:registry:margin:) -> [NodeInstance]` (pure, tested).

- [ ] **Step 1: Write the failing test**

Append to `NodeGeometryTests`:

```swift
    @Test func visibleNodesCullByViewportWithMargin() {
        let doc = ShaderDocument.sample()
        // Viewport 400×300 at zoom 1 looking at the origin: uv(0,0), time(0,160), speed(0,280), sep(220,0), mul(220,200) intersect
        // the 200 pt-expanded rect; out(1100,200) does not.
        let t = CanvasTransform(pan: .zero, zoom: 1)
        let vis = NodeGeometry.visibleNodes(in: doc.root, transform: t, viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        let ids = Set(vis.map(\.id))
        let out = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        #expect(ids.contains(uv.id))
        #expect(!ids.contains(out.id))
        #expect(vis.map(\.id.raw.uuidString) == vis.map(\.id.raw.uuidString).sorted())   // stable order
        let all = NodeGeometry.visibleNodes(in: doc.root, transform: CanvasTransform(pan: .zero, zoom: 0.15), viewport: CGSize(width: 400, height: 300), registry: reg, margin: 200)
        #expect(all.count == 11)                                                       // zoomed out, everything fits
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path MetalNodesKit --filter NodeGeometryTests 2>&1 | grep error: | head -2`
Expected: `no member 'visibleNodes'`.

- [ ] **Step 3: `NodeGeometry.visibleNodes`**

Add to `NodeGeometry`:

```swift
    /// Nodes whose frame intersects the viewport (in canvas units) grown by `margin`, in stable UUID order.
    static func visibleNodes(in graph: Graph, transform: CanvasTransform, viewport: CGSize,
                             registry: NodeRegistry, margin: CGFloat = 200) -> [NodeInstance] {
        let rect = transform.visibleRect(viewport: viewport).insetBy(dx: -margin, dy: -margin)
        return graph.nodes.values
            .filter { n in frame(for: n, registry: registry)?.intersects(rect) == true }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
    }
```

- [ ] **Step 4: `GraphCanvasView.content` — cull and LOD**

Replace the `ForEach(Array(model.document.root.nodes.values), id: \.id)` with:

```swift
            let compact = transform.zoom < Self.lodZoom
            ForEach(NodeGeometry.visibleNodes(in: model.document.root, transform: transform, viewport: viewport,
                                              registry: model.registry, margin: Self.cullMargin), id: \.id) { node in
```

with this body (the Task 6/8/11 closures, plus `compact:`):

```swift
                if case .builtin(let defID) = node.kind, let def = model.registry[defID] {
                    NodeView(node: node, def: def, resolved: model.resolvedTypes[node.id],
                             graph: model.document.root,
                             isSelected: model.selection.contains(node.id),
                             compact: compact,
                             onChange: { model.apply($0) },
                             onSelect: { mode in canvasFocused = true; model.select(node.id, mode: mode) },
                             onDragBegan: { beginNodeDrag() },
                             onDrag: { moveSelection(by: $0) },
                             onDragEnded: { endNodeDrag() },
                             onEditing: { editing in editing ? model.beginTransaction("Change Value") : model.endTransaction() },
                             dragType: pendingWire?.type,
                             onSocketDragBegan: { ref, isInput in beginWire(from: ref, isInput: isInput) },
                             onSocketDrag: { p in pendingWire?.point = p },
                             onSocketDragEnded: { p in endWire(at: p) })
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
```

Add the constants:

```swift
    static let lodZoom: CGFloat = 0.4
    static let cullMargin: CGFloat = 200
```

`viewport` was added in Task 9. Wires: `WireLayer` still receives the full graph, so wires to culled nodes draw to their last-known anchors; anchors for culled nodes are dropped from the preference dictionary when their views leave the hierarchy, so those wires simply don't draw until the node is back — acceptable for M2.

- [ ] **Step 5: `NodeView` — compact header keeps sockets**

In `NodeView.body`, the compact branch currently renders only `header`. Change the header so that in compact mode it also anchors every socket at the header's edges (so wires terminate on the collapsed node). Replace `header` with:

```swift
    private var header: some View {
        HStack(spacing: 4) {
            if compact {
                VStack(spacing: 2) {
                    ForEach(def.inputs, id: \.name) { d in
                        SocketView(type: resolved?.inputTypes[d.name] ?? concrete(d.type), dimmed: dragType != nil)
                            .socketAnchor(SocketRef(node.id, d.name)).frame(width: 6, height: 6)
                    }
                }
            }
            Text(node.customTitle ?? def.title).font(.caption.weight(.semibold)).lineLimit(1)
            Spacer()
            if compact {
                VStack(spacing: 2) {
                    ForEach(def.outputs, id: \.name) { d in
                        SocketView(type: resolved?.outputTypes[d.name] ?? concrete(d.type), dimmed: dragType != nil)
                            .socketAnchor(SocketRef(node.id, d.name)).frame(width: 6, height: 6)
                    }
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(DraculaToken.background.color)
        .background(DraculaTheme.token(for: def.category).color)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if !dragging {
                        dragging = true
                        wasSelectedAtStart = isSelected
                        let mode = InputModifiers.selectionMode()
                        if !isSelected || mode != .replace { onSelect(mode) }
                        onDragBegan()
                    }
                    onDrag(g.translation)
                }
                .onEnded { g in
                    dragging = false
                    onDragEnded()
                    if abs(g.translation.width) < 1 && abs(g.translation.height) < 1,
                       wasSelectedAtStart, InputModifiers.selectionMode() == .replace {
                        onSelect(.replace)
                    }
                }
        )
    }
```

- [ ] **Step 6: Build and run the suite**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning'; swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|error:'`
Expected: clean; three green lines.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): viewport culling with stable z-order and header-only LOD below 0.4 zoom

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 16: Integration — build, full suite, manual checklist

**Files:**
- Modify (only if a check fails): whichever file the failure points at, with the fix reported explicitly.

**Interfaces:** none new. This task is the gate for the milestone.

- [ ] **Step 1: Clean build and full suite**

```bash
swift build --package-path MetalNodesKit 2>&1 | grep -iE 'error|warning' ; echo "build-grep-done"
swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|failed'
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
git checkout -- MetalNodes.xcodeproj/project.pbxproj; rm -rf MetalNodes.xcodeproj/xcshareddata
```

Expected: no error/warning lines; three green `Test run with` lines (Core ≈ 85, Render ≈ 19, UI ≈ 60); `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Done-criteria greps**

```bash
grep -rn '0x[0-9A-Fa-f]\{6\}' MetalNodesKit/Sources --include='*.swift' | grep -v DraculaTheme          # must be empty
grep -rn '^import' MetalNodesKit/Sources/MetalNodesCore | grep -vE 'Foundation|CoreGraphics'              # must be empty
grep -rln 'import AppKit' MetalNodesKit/Sources/MetalNodesUI | xargs -I{} sh -c 'grep -L "#if os(macOS)\|#if canImport(AppKit)" {} || true'   # must be empty: every AppKit import is gated
```

- [ ] **Step 3: Launch and verify by hand**

```bash
APP=$(xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/ {print $3}')/MetalNodes.app
open "$APP"
```

Use computer-use (`request_access` for **MetalNodes**, then `screenshot` after each step). Record what each screenshot shows; never claim a check you did not see.

1. **Layout** — three panes: palette (search field, categories Input/Math/Vector/Noise/Output, "My Functions: None yet"), canvas with the sample graph, preview + gen counter + inspector showing **Document** settings (nothing selected).
2. **Select** — click the **Value Noise** node: `foreground` outline + glow; inspector shows its title, `noise.value`, category chip, a full-width **Scale** slider, `UV ← UV.uv`. ⇧-click **Color** adds it (two outlines); inspector says "2 nodes selected". Click empty canvas → nothing selected.
3. **Marquee** — drag a rectangle on empty canvas around **Time** and **Float**: both selected on release.
4. **Multi-drag + undo** — drag the **Time** header: both move together, wires follow. ⌘Z once: both return. ⇧⌘Z: both move again.
5. **Slider transaction** — scrub the **Float** slider in the inspector end-to-end (one continuous drag); Edit menu shows **Undo Change Value**; one ⌘Z restores the original value; gen counter unchanged throughout.
6. **Delete / wire select** — click the wire from **UV** to **Separate XYZ** (it turns `foreground`, thicker), press ⌫: wire gone, gen increments. ⌘Z: wire back. Select **Combine XYZ**, press ⌫: node and its four wires gone; ⌘Z restores all of them in one step.
7. **Wiring** — drag from **Time.time** output onto the **Mix** node's `t` socket (compatible sockets stay bright, `Color`'s input dims): connects, gen increments. Drag from **Mix**'s wired `a` input away and drop on empty canvas: the wire detaches and the chooser opens filtered to nodes with a compatible input; pick **Length**: a Length node appears at the drop point wired from Combine's output. Escape closes any open chooser.
8. **Palette** — drag **Value Noise** from the palette onto the canvas: a new node appears under the cursor, selected. Double-click **Smoothstep** in the palette: it appears at the viewport centre. ⇧A over the canvas opens the chooser at the cursor; typing `mi` highlights **Mix**; Return adds it.
9. **Copy/paste** — select two wired nodes, ⌘C, ⌘V: copies appear +24,+24 with their internal wire, selected. ⌘D duplicates again. ⌥-drag a node: a copy is dragged, the original stays; one ⌘Z removes the copy.
10. **Scroll/zoom** — two-finger scroll pans in the finger direction; ⌘-scroll zooms around the cursor (if the direction is inverted, flip the sign in `zoomFactor(for:precise:)` and re-verify); pinch still zooms. Home fits all nodes; select one node, press F: it fills the view.
11. **LOD/culling** — zoom out below 0.4: nodes collapse to headers with tiny sockets, wires still connect. Zoom in and pan until the output node is off-screen: no visual glitch; pan back: it reappears.
12. **Fast math** — with nothing selected, toggle **Fast math** off in the inspector: gen increments (recompile); toggle on: increments again (cache hit, still a new generation).
13. **Never black** — drag **Texture**-typed… (no texture node in M1; skip) — instead change the **Math** op to `tangent`, confirm the preview keeps rendering and the inspector shows no diagnostics.

- [ ] **Step 4: Commit any fixes**

If a check required a fix, commit it with a message naming the check (`fix(ui): <what> — manual check N`), then re-run Step 1.

- [ ] **Step 5: Report**

The report lists, per check, observed / not observed and what the screenshot showed.

---

## Done criteria for this plan

- `swift test --package-path MetalNodesKit` green; `xcodebuild … build` succeeds; warning-free.
- The 13 manual checks in Task 16 observed (10 may be sign-flipped once; 13 is a substitute check).
- No hex literal outside `DraculaTheme.swift`; `MetalNodesCore` imports only Foundation/CoreGraphics; every `AppKit` import in `MetalNodesUI` is platform-gated.
- Every edit path — node drag, slider, keyboard nudge, delete, wire, paste, duplicate, rename, settings — is a single undo step per user gesture.

## What the next plan (M3) starts from

`OutputTarget.stitchable` exists in Core but validation rejects it; `EditorViewState.viewer` is ready for the viewer flag; `Diagnostic.node` is populated from compiler lines, so error mapping onto nodes is a view change; `PaletteView`'s "My Functions" section is the M4 hook; `GraphClipboard.definitions/stickies/frames` are carried but empty.
