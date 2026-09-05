# MetalNodes M3 — Library, Viewer, Stitchable Target, Error Mapping — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Grow the M2 editor into the full v1 shader tool: the complete v1 node library (minus textures), a viewer flag that previews any socket, a SwiftUI `[[stitchable]]` output target with `.metal` + `.swift` export, and compiler/validation errors drawn on the offending nodes.

**Architecture:** Codegen gains an *emit environment* (how uniforms and the four system values are spelled) so one emitter serves the fragment program, the viewer program and a stitchable function. `ShaderGenerator.generate` takes an optional viewer socket (preview-only, always a fragment program) and a target from `DocumentSettings`. Export is a pure function from document to two text files. The library grows as data (`NodeDef` + `mn_` MSL helpers); anything needing temporaries becomes a stdlib function so instances never collide. UI work is thin: badges on `NodeView`, a viewer strip in the preview pane, output rows in the inspector, a target picker + export in document settings, and a save panel behind `#if os(macOS)`.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 / iPadOS 27), AppKit only for `NSSavePanel` (macOS branch), Metal, Swift Testing, SwiftPM local package `MetalNodesKit`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §7 (types), §8 (node definitions), §9.3 (viewer), §9.4 (error mapping), §9.5 (stitchable), §9.6 (uniforms), §12 (theme), §13 (library), §14 (testing) and **§19 (M3 addendum)**, which pins the mechanics. Read §19 in full before any task.

## Global Constraints

- Swift language mode `6`, strict concurrency, warning-free build (`swift build --package-path MetalNodesKit 2>&1 | grep -i warning` prints nothing).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics`. `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore` (+ SwiftUI only in `PreviewView.swift`). `MetalNodesUI` may import AppKit **only** inside `#if os(macOS)` / `#if canImport(AppKit)` and only in files whose name ends in `Mac.swift` or in a clearly gated section; the `#else` branch must keep the iPad build plausible.
- `MetalNodesUI` and `MetalNodesUITests` have `.defaultIsolation(MainActor.self)`; Core and Render do not. Static regexes and `UTType`s in the UI module need `nonisolated`; `Shape` conformances need `nonisolated` members.
- Colors only through `DraculaTheme` / `DraculaToken`. No hex literals outside `DraculaTheme.swift`. Red = errors only (`DraculaTheme.error`). Viewer flag = green ◉ (`DraculaTheme.viewerFlag`), SF Symbols `circle.circle` / `circle.circle.fill`.
- Every document edit goes through `EditorModel.apply(_:)`; views never mutate `document` directly. Classification stays: cosmetic → nothing; parameter → uniform write, no compile; topology → debounced compile. Viewer and viewer range are **view/preview state**: never undone, never a `DocumentChange`.
- Undo = whole-document snapshots in transactions (spec §5, §18.3). View state (`EditorViewState`) is never snapshotted.
- Templates spell system values as `{sys.uv}`, `{sys.time}`, `{sys.resolution}`, `{sys.mouse}` — never `u.time` / `in.uv` literally (spec §19.2). Every multi-statement node body that needs a temporary is a `mn_` stdlib function, not a template.
- Stitchable argument order = `float2 mouse` then user uniform slots **in layout order**; int/bool slots are `float` arguments cast on read (spec §19.4). Function name = sanitized `settings.exportName`, default `metalNodesShader`.
- Node width stays `190`; a `.dot` node is `24 × 24`. Culling margin 200, LOD below 0.4 unchanged.
- Tests: Swift Testing only. Package suite: `swift test --package-path MetalNodesKit`. App build: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build`. Golden strings are compared whole; when a golden changes, paste the new text, don't loosen the assertion. Under the Swift Testing `#expect` macro, compare against **single typed literals** (`130`, not `26 + 16 + 4 * 22`).
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- Never commit `MetalNodes.xcodeproj/project.pbxproj` key reorders (`git checkout -- MetalNodes.xcodeproj/project.pbxproj` before committing unless the task explicitly edits a build setting) or the `xcshareddata/` directory `xcodebuild` sometimes creates.

---

## File structure

**Core (`MetalNodesKit/Sources/MetalNodesCore`)**
- Create `Codegen/EmitEnvironment.swift` — how uniforms and `sys` values are spelled per target (T1).
- Create `Codegen/SourceBuilder.swift` — appends lines, tracks owners into a `LineMap` (T1).
- Modify `Codegen/Emitter.swift` — takes an environment; exposes `outputVars` and per-node `inputExpressions` (T1).
- Modify `Codegen/UniformLayout.swift` — reserved list is a parameter; `hasReserved` (T1).
- Modify `NodeDef.swift` — `NodeStyle`, `ParamDecl.showsInBody`, `EmitContext.sys` (T1).
- Modify `NodeRegistry.swift` — `{sys.x}` placeholder validation (T1).
- Modify `ShaderDocument.swift` + `Codegen/Diagnostic.swift` — `DocumentSettings.target/exportName`, `OutputTarget: Codable`, `OutputTarget.all/title` (T1).
- Modify `Library/BuiltinNodes.swift` — templates use `{sys.*}`; becomes the concatenation of per-category lists (T1, T6–T8).
- Modify `Codegen/TypeResolver.swift` — exact-type rule (T2).
- Create `Codegen/ViewerWrap.swift` (T3). Modify `Codegen/ShaderGenerator.swift` — `viewer:`, per-target assembly, `exportSource` (T3, T4). Modify `Codegen/Validation.swift` — drop the stitchable rejection, `isValidViewer` (T3).
- Create `Codegen/StitchableCodegen.swift` (T4). Create `Export/ShaderExport.swift` (T5).
- Create `Library/Builtin/InputNodes.swift`, `MathNodes.swift`, `VectorNodes.swift` (T6), `SDFNodes.swift`, `NoiseNodes.swift` (T7), `ColorNodes.swift`, `UtilityNodes.swift` (T8). Modify `Library/MSLStdlib.swift` — split its table into `Library/Stdlib/*.swift` extensions (T6–T8).
- Modify `Clipboard/GraphClipboard.swift` — tolerant decoding (T11).

**Render (`MetalNodesKit/Sources/MetalNodesRender`)**
- Modify `PreviewState.swift` (`viewerRange`), `UniformImage.swift` (`setViewerRange`), `ShaderRenderer.swift` (writes it) (T9).

**UI (`MetalNodesKit/Sources/MetalNodesUI`)**
- Create `Editor/EditorModel+Viewer.swift` (T9). Modify `Editor/EditorModel.swift` — viewer in codegen, prune, unchanged-source skip, `errorNodes`, `socketLabel`, export request (T9, T13).
- Modify `Canvas/NodeView.swift` — viewer/error badges, error outline, `.dot` body, `showsInBody` (T10, T11). Modify `Canvas/NodeGeometry.swift` — dot size/anchors, body rows, `onTop` ordering (T11). Modify `Canvas/GraphCanvasView.swift` — plumbing, paste at hover, z-order (T10, T11).
- Modify `Editor/EditorView.swift` — viewer strip, mouse tracking overlay, export panel hook (T10, T12, T13). Modify `Editor/InspectorView.swift` — output rows with ◉, target picker, export name, copy snippet (T10, T13). Modify `Editor/EditorCommands.swift` — ⌘⇧V, ⌘E, undo titles (T10, T11, T13).
- Create `Editor/ExportPanelMac.swift` (T13).

**App**
- Modify `MetalNodes.xcodeproj/project.pbxproj` — `ENABLE_USER_SELECTED_FILES = readwrite` on the app target (T13).

**Tests** — new suites `EmitEnvironmentTests`, `ViewerCodegenTests`, `StitchableCodegenTests`, `ShaderExportTests`, `LibraryM3Tests` (Core); `ViewerRenderTests` additions in `ShaderCompilerTests`, `UniformImageTests` (Render); `EditorViewerTests`, additions to `EditorModelTests`, `NodeGeometryTests` (UI).

---

### Task 1: Emit environment, `{sys.*}` placeholders, settings, `NodeDef` additions

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/SourceBuilder.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/UniformLayout.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeRegistry.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/EmitEnvironmentTests.swift`, `DocumentSettingsTests.swift`, `NodeRegistryTests.swift`

**Interfaces:**
- Produces: `EmitEnvironment` (`.fragment`, `.stitchableFunction`, `sysNames`); `SourceBuilder`; `Emitter.emit(order:graph:registry:resolved:env:reserved:)` whose `Output` has `outputVars: [SocketRef: String]` and `inputExpressions: [NodeID: [String: String]]`; `UniformLayoutBuilder.build(_:reserved:)`, `UniformLayoutBuilder.standardReserved`, `viewerReserved`, `UniformLayout.hasReserved(_:)`; `NodeStyle`, `NodeDef.style`, `ParamDecl.showsInBody`, `EmitContext.sys`; `DocumentSettings.target: OutputTarget`, `DocumentSettings.exportName: String`; `OutputTarget: Codable`, `OutputTarget.all`, `.title`, `.stitchableKind`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing tests**

`MetalNodesKit/Tests/MetalNodesCoreTests/EmitEnvironmentTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct EmitEnvironmentTests {
    private func field(_ name: String, _ type: SocketType) -> UniformField {
        UniformField(name: name, mslType: type.uniformStorageName ?? type.mslName, offset: 0, size: type.byteSize ?? 0, type: type, path: nil)
    }

    @Test func fragmentEnvironmentReadsTheUniformStruct() {
        let env = EmitEnvironment.fragment
        #expect(env.uniform(field("p0", .float)) == "u.p0")
        #expect(env.uniform(field("p3", .int)) == "u.p3")
        #expect(env.uniform(field("p4", .bool)) == "bool(u.p4)")
        #expect(env.sys["uv"] == "in.uv")
        #expect(env.sys["time"] == "u.time")
        #expect(env.sys["resolution"] == "u.resolution")
        #expect(env.sys["mouse"] == "u.mouse")
    }

    @Test func stitchableEnvironmentReadsArgumentsAndCastsScalars() {
        let env = EmitEnvironment.stitchableFunction
        #expect(env.uniform(field("p0", .float)) == "p0")
        #expect(env.uniform(field("p3", .int)) == "int(p3)")
        #expect(env.uniform(field("p4", .bool)) == "bool(p4)")
        #expect(env.sys["uv"] == "uv")
        #expect(env.sys["resolution"] == "size")
        #expect(env.sys["mouse"] == "mouse")
    }

    @Test func sysPlaceholdersAreSubstitutedFromTheEnvironment() {
        let ctx = EmitContext(inputs: [:], outputs: ["o": "v0"], params: [:], enums: [:], types: [:],
                              sys: ["uv": "in.uv", "time": "u.time"])
        #expect(Emitter.substitute("{out.o} = {sys.uv} * {sys.time};", ctx) == ["v0 = in.uv * u.time;"])
    }

    @Test func layoutTakesItsReservedList() {
        let l = UniformLayoutBuilder.build([], reserved: UniformLayoutBuilder.viewerReserved)
        #expect(l.hasReserved("viewerMin"))
        #expect(l.hasReserved("viewerMax"))
        #expect(!UniformLayoutBuilder.build([]).hasReserved("viewerMin"))
        #expect(l.reserved("viewerMax").offset == 24)     // float2, float2, float, float, float
    }

    @Test func sourceBuilderTracksOwnersAcrossMultiLineChunks() {
        let a = NodeID(), b = NodeID()
        var s = SourceBuilder()
        s.add("header")                      // line 1
        s.add("x;\ny;", owner: a)            // lines 2–3
        s.add("z;", owner: a)                // line 4, merges
        s.add("w;", owner: b)                // line 5
        #expect(s.text == "header\nx;\ny;\nz;\nw;\n")
        #expect(s.map.lines(for: a) == [2...4])
        #expect(s.map.node(forLine: 5) == b)
    }
}
```

Add to `NodeRegistryTests.swift`:

```swift
    @Test func sysPlaceholdersMustNameASystemValue() {
        let ok = NodeDef(id: "t.ok", title: "ok", category: .input,
                         outputs: [SocketDecl(name: "o", type: .concrete(.float2))],
                         body: .template("{out.o} = {sys.uv} + {sys.mouse};"))
        #expect(throws: Never.self) { try NodeRegistry([ok]) }
        let bad = NodeDef(id: "t.bad", title: "bad", category: .input,
                          outputs: [SocketDecl(name: "o", type: .concrete(.float))],
                          body: .template("{out.o} = {sys.frame};"))
        #expect(throws: RegistryError.unknownPlaceholder(def: "t.bad", placeholder: "sys.frame")) { try NodeRegistry([bad]) }
    }

    @Test func paramsCanBeHiddenFromTheNodeBody() {
        let p = ParamDecl(name: "pos1", kind: .value(.float, range: 0...1), defaultValue: .float(0.5), showsInBody: false)
        #expect(!p.showsInBody)
        #expect(ParamDecl(name: "x", kind: .value(.float, range: nil), defaultValue: .float(0)).showsInBody)
        #expect(NodeDef(id: "t.dot", title: "Dot", category: .utility, body: .template(""), style: .dot).style == .dot)
    }
```

Add to `DocumentSettingsTests.swift`:

```swift
    @Test func targetAndExportNameRoundTripAndDefault() throws {
        var s = DocumentSettings()
        #expect(s.target == .fragment)
        #expect(s.exportName == "metalNodesShader")
        s.target = .stitchable(.distortionEffect)
        s.exportName = "ripple"
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(back.target == .stitchable(.distortionEffect))
        #expect(back.exportName == "ripple")
        let legacy = try JSONDecoder().decode(DocumentSettings.self, from: Data(#"{"fastMath":false}"#.utf8))
        #expect(legacy.target == .fragment)
        #expect(legacy.exportName == "metalNodesShader")
    }

    @Test func outputTargetsHaveTitlesAndAStableOrder() {
        #expect(OutputTarget.all.count == 4)
        #expect(OutputTarget.all.first == .fragment)
        #expect(OutputTarget.stitchable(.layerEffect).title == "SwiftUI Layer Effect")
        #expect(OutputTarget.stitchable(.colorEffect).stitchableKind == .colorEffect)
        #expect(OutputTarget.fragment.stitchableKind == nil)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --package-path MetalNodesKit --filter "EmitEnvironmentTests|NodeRegistryTests|DocumentSettingsTests"`
Expected: compile errors (`EmitEnvironment`, `SourceBuilder`, `showsInBody`, `style`, `target` unknown).

- [ ] **Step 3: Implement**

`Codegen/EmitEnvironment.swift`:

```swift
import Foundation

/// How generated statements spell a uniform read and the four system values (spec §19.2).
/// One emitter serves every target; only this differs.
public struct EmitEnvironment: Sendable {
    public var uniform: @Sendable (UniformField) -> String
    public var sys: [String: String]

    public static let sysNames: Set<String> = ["uv", "time", "resolution", "mouse"]

    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: String]) {
        self.uniform = uniform
        self.sys = sys
    }

    /// The fragment program (and every viewer program): a `constant Uniforms &u` buffer.
    public static let fragment = EmitEnvironment(
        uniform: { f in f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)" },
        sys: ["uv": "in.uv", "time": "u.time", "resolution": "u.resolution", "mouse": "u.mouse"])

    /// Inside a stitchable function: uniforms are arguments named after their slots; SwiftUI has
    /// no int/bool `Shader.Argument`, so those arrive as `float` and are cast on read.
    public static let stitchableFunction = EmitEnvironment(
        uniform: { f in
            switch f.type {
            case .bool: "bool(\(f.name))"
            case .int: "int(\(f.name))"
            default: f.name
            }
        },
        sys: ["uv": "uv", "time": "time", "resolution": "size", "mouse": "mouse"])
}
```

`Codegen/SourceBuilder.swift`:

```swift
import Foundation

/// Accumulates generated source and the node that owns each line (spec §9.4).
struct SourceBuilder {
    private(set) var text = ""
    private(set) var map = LineMap()
    private var nextLine = 1

    /// Appends `chunk` plus a trailing newline. Multi-line chunks attribute every line to `owner`;
    /// consecutive lines with the same owner merge into one `LineMap` entry.
    mutating func add(_ chunk: String, owner: NodeID? = nil) {
        let count = chunk.split(separator: "\n", omittingEmptySubsequences: false).count
        let first = nextLine, last = nextLine + count - 1
        nextLine += count
        text += chunk + "\n"
        guard let owner else { return }
        if let prev = map.entries.last, prev.node == owner, prev.range.upperBound == first - 1 {
            map.entries[map.entries.count - 1] = LineMap.Entry(range: prev.range.lowerBound...last, node: owner)
        } else {
            map.entries.append(LineMap.Entry(range: first...last, node: owner))
        }
    }
}
```

`Codegen/UniformLayout.swift` — replace `reservedNames`, `reserved(_:)` and the builder:

```swift
    /// Names of the path-less (reserved) fields, in struct order.
    public var reservedNames: [String] { fields.filter { $0.path == nil }.map(\.name) }

    public func hasReserved(_ name: String) -> Bool { fields.contains { $0.path == nil && $0.name == name } }

    public func reserved(_ name: String) -> UniformField {
        guard let f = fields.first(where: { $0.path == nil && $0.name == name }) else {
            preconditionFailure("unknown reserved uniform \(name)")
        }
        return f
    }
```

```swift
public enum UniformLayoutBuilder {
    public typealias Reserved = (name: String, type: SocketType)

    /// Every program has these three (spec §9.6).
    public static let standardReserved: [Reserved] = [("resolution", .float2), ("mouse", .float2), ("time", .float)]
    /// Viewer programs add the manual range for float/int visualisation (spec §19.3).
    public static let viewerReserved: [Reserved] = standardReserved + [("viewerMin", .float), ("viewerMax", .float)]

    public static func build(_ requests: [(path: ParamPath, type: SocketType)],
                             reserved: [Reserved] = standardReserved) -> UniformLayout {
        struct Pending { let path: ParamPath?; let name: String?; let type: SocketType }
        var pending: [Pending] = reserved.map { Pending(path: nil, name: $0.name, type: $0.type) }
        pending += requests.filter { $0.type.isUniformable }.map { Pending(path: $0.path, name: nil, type: $0.type) }
        // … the rest of the existing body is unchanged (stable alignment sort, offsets, names) …
```

`NodeDef.swift` additions:

```swift
public struct ParamDecl: Sendable, Hashable {
    public var name: String
    public var label: String
    public var kind: ParamKind
    public var defaultValue: ParamValue
    /// False hides the control from the node body; the inspector still shows it (spec §19.5).
    public var showsInBody: Bool

    public init(name: String, label: String? = nil, kind: ParamKind, defaultValue: ParamValue, showsInBody: Bool = true) {
        self.name = name
        self.label = label ?? name.capitalized
        self.kind = kind
        self.defaultValue = defaultValue
        self.showsInBody = showsInBody
    }
}

/// How the canvas draws a node (spec §19.5).
public enum NodeStyle: Sendable, Hashable {
    case standard
    /// A 24 × 24 dot with one input on the left and one output on the right (Reroute).
    case dot
}
```

`EmitContext` gains `public var sys: [String: String]` (last init parameter, default `[:]`). `NodeDef` gains `public var style: NodeStyle` (init parameter `style: NodeStyle = .standard`, after `body`).

`NodeRegistry.swift`: pattern becomes `/\{(in|out|param|type|sys)\.([A-Za-z_][A-Za-z0-9_]*)\}/` and `checkPlaceholders` adds `case "sys": EmitEnvironment.sysNames.contains(name)`.

`Emitter.swift` — signature and the three touch points:

```swift
    static func emit(order: [NodeID], graph: Graph, registry: NodeRegistry,
                     resolved: [NodeID: ResolvedNode],
                     env: EmitEnvironment = .fragment,
                     reserved: [UniformLayoutBuilder.Reserved] = UniformLayoutBuilder.standardReserved) -> Output {
```
- `Output` gains `var outputVars: [SocketRef: String] = [:]` and `var inputExpressions: [NodeID: [String: String]] = [:]`.
- `var out = Output(layout: UniformLayoutBuilder.build(requests, reserved: reserved))`.
- `uniformExpr(_ path:)` becomes `env.uniform(out.layout.field(for: path)!)`.
- `case .uv: inputs[decl.name] = env.sys["uv"] ?? "in.uv"`.
- After the input loop: `out.inputExpressions[id] = inputs`; the existing local `outputVars` becomes `out.outputVars`.
- `EmitContext(... types: r.generics, sys: env.sys)`; `substitute` adds `case "sys": return ctx.sys[name] ?? "/* ?sys.\(name) */"`.

`ShaderGenerator.generate` (only what T1 changes; T3/T4 restructure it): build the source with `SourceBuilder` instead of the inline `bodyStart` arithmetic — `add("#include <metal_stdlib>\nusing namespace metal;\n")`, `add(emitted.layout.mslStruct + "\n")`, `add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")`, one `add(f.source + "\n")` per stdlib function, `add("fragment float4 shaderMain(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")`, then one `add("    " + line, owner: emitted.lineOwners[i])` per body line, then `add("}")`. The golden in `ShaderGeneratorTests.goldenSource` must still pass byte-for-byte — that is the test of this refactor.

`Diagnostic.swift` — `OutputTarget`:

```swift
public enum OutputTarget: Sendable, Hashable, Codable {
    case fragment
    case stitchable(StitchableKind)

    public static let all: [OutputTarget] = [.fragment, .stitchable(.colorEffect), .stitchable(.distortionEffect), .stitchable(.layerEffect)]

    public var title: String {
        switch self {
        case .fragment: "Fragment (preview)"
        case .stitchable(.colorEffect): "SwiftUI Color Effect"
        case .stitchable(.distortionEffect): "SwiftUI Distortion Effect"
        case .stitchable(.layerEffect): "SwiftUI Layer Effect"
        }
    }

    public var stitchableKind: StitchableKind? {
        if case .stitchable(let k) = self { return k } else { return nil }
    }
}
```

`ShaderDocument.swift` — `DocumentSettings` gains `public var target: OutputTarget = .fragment` and `public var exportName: String = "metalNodesShader"`; the hand-written `Codable` adds keys `target`, `exportName` with `decodeIfPresent` defaults `.fragment` / `"metalNodesShader"` and encodes both.

`Library/BuiltinNodes.swift` — migrate the four templates: UV `"normalized": "{out.uv} = {sys.uv};"`, `"aspect": "{out.uv} = ({sys.uv} - 0.5) * ({sys.resolution} / {sys.resolution}.y);"`; Time `"{out.time} = {sys.time};"`; Resolution `"{out.resolution} = {sys.resolution};"`.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path MetalNodesKit`
Expected: all green, including `ShaderGeneratorTests.goldenSource` unchanged (the sample document's source must be byte-identical to before — `ShaderCompilerTests.identicalSourceHitsTheCache` and the goldens prove it).

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): emit environment with {sys.*} placeholders, SourceBuilder, reserved-list layouts, NodeStyle/showsInBody, settings.target/exportName"
```

---

### Task 2: Exact-type preference in generic resolution

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/TypeResolver.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TypeResolverTests.swift`

**Interfaces:**
- Produces: rule (spec §19.5): if every connected input of a generic has the **same** source type and that type is in the allowed set, the generic resolves to it exactly; otherwise the existing widen-by-component-count rule applies.

- [ ] **Step 1: Write the failing test**

```swift
    @Test func genericKeepsAnExactlyMatchingSourceType() throws {
        // A pass-through allowing color AND float4 must keep `color` as `color`, not widen to float4.
        let reroute = NodeDef(id: "t.pass", title: "Pass", category: .utility,
                              inputs: [SocketDecl(name: "in", type: .generic("T"), default: .value(.float(0)))],
                              outputs: [SocketDecl(name: "out", type: .generic("T"))],
                              generics: ["T": [.float, .float2, .float3, .float4, .color, .int, .bool]],
                              body: .template("{out.out} = {in.in};"))
        let reg = try NodeRegistry(BuiltinNodes.all + [reroute])
        let c = NodeInstance(kind: .builtin("input.color"))
        let p = NodeInstance(kind: .builtin("t.pass"))
        var g = Graph(); g.nodes[c.id] = c; g.nodes[p.id] = p
        g.connect(SocketRef(c.id, "out"), to: SocketRef(p.id, "in"))
        let (nodes, diags) = TypeResolver.resolve(g, registry: reg, order: [c.id, p.id])
        #expect(diags.isEmpty)
        #expect(nodes[p.id]?.outputTypes["out"] == .color)
    }

    @Test func mixedSourceTypesStillWiden() throws {
        // float + float3 into Math → float3, unchanged behaviour.
        let f = NodeInstance(kind: .builtin("input.float")), v = NodeInstance(kind: .builtin("vector.combine"))
        let m = NodeInstance(kind: .builtin("math.math"))
        var g = Graph(); for n in [f, v, m] { g.nodes[n.id] = n }
        g.connect(SocketRef(f.id, "out"), to: SocketRef(m.id, "a"))
        g.connect(SocketRef(v.id, "out"), to: SocketRef(m.id, "b"))
        let (nodes, _) = TypeResolver.resolve(g, registry: .builtin, order: [f.id, v.id, m.id])
        #expect(nodes[m.id]?.outputTypes["out"] == .float3)
    }
```

- [ ] **Step 2: Run to see the first fail** (`swift test --package-path MetalNodesKit --filter TypeResolverTests`): expected `.float4` instead of `.color`.

- [ ] **Step 3: Implement** — in `TypeResolver.resolve`, step 1 becomes:

```swift
            for (name, allowed) in def.generics {
                let s = allowed.sorted { ($0.componentCount ?? 0) < ($1.componentCount ?? 0) }
                var sources: [SocketType] = []
                for decl in def.inputs where decl.type == .generic(name) {
                    guard let src = graph.inputs[SocketRef(id, decl.name)],
                          let srcType = resolved[src.node]?.outputTypes[src.socket] else { continue }
                    sources.append(srcType)
                }
                if let first = sources.first, sources.allSatisfy({ $0 == first }), allowed.contains(first) {
                    generics[name] = first                       // spec §19.5: exact match wins
                } else if let n = sources.map({ $0.componentCount ?? 0 }).max() {
                    generics[name] = s.first { ($0.componentCount ?? 0) >= n } ?? s.last ?? .float
                } else {
                    generics[name] = s.contains(.float) ? .float : (s.first ?? .float)
                }
            }
```

- [ ] **Step 4: Run** `swift test --package-path MetalNodesKit --filter "TypeResolverTests|ShaderGeneratorTests"` — green. `colorFeedingGenericResolvesToFloat4` (Math's `T` does not allow `color`) must still pass.

- [ ] **Step 5: Commit** — `feat(core): generics keep an exactly matching source type`

---

### Task 3: Viewer codegen

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ViewerWrap.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ViewerCodegenTests.swift`, `ValidationTests.swift`

**Interfaces:**
- Produces: `ShaderGenerator.generate(_:target:viewer:registry:)` (`viewer: SocketRef? = nil`); `GeneratedShader.viewer: SocketRef?`; `ViewerWrap.statement(variable:type:) -> String?`; `GraphValidator.isValidViewer(_:in:registry:) -> Bool`.
- Consumes: T1 (`SourceBuilder`, `viewerReserved`, `Emitter.Output.outputVars`).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct ViewerCodegenTests {
    /// One constant node of `defID` plus a Fragment Output (unwired), viewer on the constant.
    private func oneNode(_ defID: String, socket: String = "out") -> (ShaderDocument, SocketRef) {
        let n = NodeInstance(kind: .builtin(defID)), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[n.id] = n; d.root.nodes[out.id] = out
        return (d, SocketRef(n.id, socket))
    }

    @Test func wrapStatementsPerType() {
        #expect(ViewerWrap.statement(variable: "v1", type: .float) ==
                "return float4(float3(saturate((v1 - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .int) ==
                "return float4(float3(saturate((float(v1) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float2) == "return float4(v1, 0.0, 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float3) == "return float4(v1, 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float4) == "return v1;")
        #expect(ViewerWrap.statement(variable: "v1", type: .color) == "return v1;")
        #expect(ViewerWrap.statement(variable: "v1", type: .bool) == "return float4(float3(v1 ? 1.0 : 0.0), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .texture) == nil)
    }

    @Test func viewerProgramEndsAtTheViewedNodeAndHasTheRange() throws {
        let (doc, ref) = oneNode("input.float")
        let s = try ShaderGenerator.generate(doc, viewer: ref)
        #expect(s.viewer == ref)
        #expect(s.target == .fragment)
        #expect(s.layout.hasReserved("viewerMin") && s.layout.hasReserved("viewerMax"))
        #expect(s.source.contains("u.viewerMin"))
        #expect(!s.source.contains("/* unconnected */"))
        // The wrap line is owned by the viewed node.
        let wrapLine = s.source.components(separatedBy: "\n").firstIndex { $0.contains("return float4(float3(saturate") }! + 1
        #expect(s.lineMap.node(forLine: wrapLine) == ref.node)
        #expect(s.source.contains("return float4(float3(saturate((v0 - u.viewerMin)"))
    }

    @Test func fragmentProgramsHaveNoRangeUniforms() throws {
        let s = try ShaderGenerator.generate(ShaderDocument.sample())
        #expect(!s.layout.hasReserved("viewerMin"))
        #expect(s.viewer == nil)
    }

    @Test func viewerOnEveryConstantTypeGenerates() throws {
        for (def, socket) in [("input.float", "out"), ("input.color", "out"), ("input.uv", "uv"), ("vector.combine", "out")] {
            let (doc, ref) = oneNode(def, socket: socket)
            let s = try ShaderGenerator.generate(doc, viewer: ref)
            #expect(s.source.hasSuffix("}\n"), "\(def)")
            #expect(s.source.contains("return "), "\(def)")
        }
    }

    @Test func viewerUnderAStitchableTargetIsStillAFragmentProgram() throws {
        var (doc, ref) = oneNode("input.float")
        doc.settings.target = .stitchable(.colorEffect)
        let s = try ShaderGenerator.generate(doc, target: doc.settings.target, viewer: ref)
        #expect(s.target == .fragment)
        #expect(s.exportSource == nil)
        #expect(s.source.contains("fragment float4 shaderMain"))
    }

    @Test func viewerDCEDropsNodesNotUpstreamOfTheViewedOne() throws {
        let doc = ShaderDocument.sample()
        let noise = doc.root.nodes.values.first { $0.kind == .builtin("noise.value") }!
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(noise.id, "out"))
        #expect(s.source.contains("mn_valueNoise"))
        // Only the noise's `scale` slot survives: Speed and the tint colour feed nodes downstream of the viewer.
        #expect(s.layout.fields.filter { $0.path != nil }.count == 1)
    }

    @Test func aMissingViewerSocketIsADiagnostic() {
        let (doc, ref) = oneNode("input.float")
        let bad = SocketRef(ref.node, "nope")
        #expect(!GraphValidator.isValidViewer(bad, in: doc.root, registry: .builtin))
        #expect(throws: GenerationError.invalid([Diagnostic(.error, "The viewed socket no longer exists", node: ref.node, socket: "nope")])) {
            try ShaderGenerator.generate(doc, viewer: bad)
        }
    }
}
```

- [ ] **Step 2: Run to see them fail** — `swift test --package-path MetalNodesKit --filter ViewerCodegenTests`: compile errors (`viewer:` label, `ViewerWrap`, `exportSource`).

- [ ] **Step 3: Implement**

`Codegen/ViewerWrap.swift`:

```swift
import Foundation

/// The last statement of a viewer program (spec §9.3, §19.3).
public enum ViewerWrap {
    public static func statement(variable v: String, type: SocketType) -> String? {
        switch type {
        case .float: "return float4(float3(saturate((\(v) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);"
        case .int: "return float4(float3(saturate((float(\(v)) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);"
        case .float2: "return float4(\(v), 0.0, 1.0);"
        case .float3: "return float4(\(v), 1.0);"
        case .float4, .color: "return \(v);"
        case .bool: "return float4(float3(\(v) ? 1.0 : 0.0), 1.0);"
        case .texture: nil
        }
    }
}
```

`Validation.swift` — delete the `if case .stitchable = target` rejection and add:

```swift
    /// A viewer must name an existing builtin node's output of a viewable (non-texture) type.
    public static func isValidViewer(_ ref: SocketRef, in graph: Graph, registry: NodeRegistry) -> Bool {
        guard let n = graph.nodes[ref.node], case .builtin(let id) = n.kind, let def = registry[id],
              let decl = def.output(named: ref.socket) else { return false }
        if case .concrete(.texture) = decl.type { return false }
        return true
    }
```

`GeneratedShader` — add stored properties `viewer: SocketRef?`, `exportSource: String?`, `functionName: String` and extend the memberwise init with defaults so existing callers compile: `init(source:layout:lineMap:resolved:fragmentFunctionName:target:viewer: SocketRef? = nil, exportSource: String? = nil, functionName: String = "")`.

`ShaderGenerator.generate`:

```swift
    public static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment, viewer: SocketRef? = nil,
                                registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { throw .invalid(structural) }
        if let v = viewer, !GraphValidator.isValidViewer(v, in: doc.root, registry: registry) {
            throw .invalid([Diagnostic(.error, "The viewed socket no longer exists", node: v.node, socket: v.socket)])
        }
        let terminal = GraphValidator.terminal(in: doc.root)!
        let start = viewer?.node ?? terminal
        let order = TopoSort.order(doc.root, from: start)
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(structural + typeDiags) }

        // A viewer is a preview concept: always a fragment program (spec §19.3).
        let effectiveTarget: OutputTarget = viewer == nil ? target : .fragment
        switch effectiveTarget {
        case .fragment:
            return assembleFragment(doc, order: order, terminal: terminal, viewer: viewer, resolved: resolved, registry: registry)
        case .stitchable(let kind):
            return assembleStitchable(doc, kind: kind, order: order, terminal: terminal, resolved: resolved, registry: registry) // T4
        }
    }

    private static func assembleFragment(_ doc: ShaderDocument, order: [NodeID], terminal: NodeID, viewer: SocketRef?,
                                         resolved: [NodeID: ResolvedNode], registry: NodeRegistry) -> GeneratedShader {
        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved,
                                   env: .fragment,
                                   reserved: viewer == nil ? UniformLayoutBuilder.standardReserved : UniformLayoutBuilder.viewerReserved)
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>\nusing namespace metal;\n")
        b.add(emitted.layout.mslStruct + "\n")
        b.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in MSLStdlib.resolve(emitted.requiredStdlib) { b.add(f.source + "\n") }
        b.add("fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")
        for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]) }
        if let v = viewer, let variable = emitted.outputVars[v], let type = resolved[v.node]?.outputTypes[v.socket],
           let wrap = ViewerWrap.statement(variable: variable, type: type) {
            b.add("    " + wrap, owner: v.node)
        }
        b.add("}")
        return GeneratedShader(source: b.text, layout: emitted.layout, lineMap: b.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: .fragment, viewer: viewer)
    }
```

Until T4 lands, `assembleStitchable` is a one-line stub that calls `assembleFragment` (T4 replaces it); `ValidationTests.stitchableTargetIsRejectedUntilM3` is deleted in this task (its premise is gone) and replaced by `stitchableTargetsValidateLikeFragment` asserting the sample document has no diagnostics under `.stitchable(.colorEffect)`.

- [ ] **Step 4: Run** `swift test --package-path MetalNodesKit` — green.

- [ ] **Step 5: Commit** — `feat(core): viewer programs — generate(viewer:), ViewerWrap, viewerMin/Max reserved uniforms`

---

### Task 4: Stitchable codegen (function, preview wrapper, export source)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/StitchableCodegen.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/StitchableCodegenTests.swift`

**Interfaces:**
- Produces: `StitchableCodegen.sanitizedName(_:)`, `StitchableCodegen.Argument { name, mslType, field: UniformField? }`, `StitchableCodegen.arguments(layout:)`, `signature(kind:name:args:forExport:)`, `returnStatement(kind:color:)`, `previewBody(kind:name:args:)`; `GeneratedShader.exportSource` (non-nil for stitchable targets), `GeneratedShader.functionName`.
- Consumes: T1 env/`inputExpressions`, T3 assembly structure.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct StitchableCodegenTests {
    private func smallDocument(_ kind: StitchableKind, name: String = "ripple") -> ShaderDocument {
        func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
        let uv = NodeInstance(id: id(1), kind: .builtin("input.uv"))
        let sep = NodeInstance(id: id(2), kind: .builtin("vector.separate"))
        let comb = NodeInstance(id: id(3), kind: .builtin("vector.combine"), params: ["z": .float(0.5)])
        let out = NodeInstance(id: id(4), kind: .builtin("output.fragment"))
        var g = Graph()
        for n in [uv, sep, comb, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(uv.id, "uv"), to: SocketRef(sep.id, "v"))
        g.connect(SocketRef(sep.id, "x"), to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"), to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(comb.id, "out"), to: SocketRef(out.id, "color"))
        var d = ShaderDocument(); d.root = g
        d.settings.target = .stitchable(kind); d.settings.exportName = name
        return d
    }

    @Test func namesAreSanitisedToIdentifiers() {
        #expect(StitchableCodegen.sanitizedName("ripple") == "ripple")
        #expect(StitchableCodegen.sanitizedName("My Cool Shader!") == "My_Cool_Shader_")
        #expect(StitchableCodegen.sanitizedName("9lives") == "_9lives")
        #expect(StitchableCodegen.sanitizedName("   ") == "metalNodesShader")
        #expect(StitchableCodegen.sanitizedName("") == "metalNodesShader")
    }

    @Test func argumentsAreMouseThenSlotsInLayoutOrderWithScalarsAsFloat() {
        let a = NodeID(), b = NodeID()
        let layout = UniformLayoutBuilder.build([(ParamPath(node: a, param: "i"), .int), (ParamPath(node: b, param: "v"), .float3), (ParamPath(node: a, param: "f"), .bool)])
        let args = StitchableCodegen.arguments(layout: layout)
        #expect(args.map(\.name) == ["mouse", "p0", "p1", "p2"])       // float3 sorts first (alignment 16)
        #expect(args.map(\.mslType) == ["float2", "float3", "float", "float"])
        #expect(args[0].field == nil)
        #expect(args[1].field?.type == .float3)
    }

    @Test func colorEffectExportGolden() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        let expected = """
        #include <metal_stdlib>
        using namespace metal;

        [[stitchable]] half4 ripple(float2 position, half4 currentColor, float2 size, float time, float2 mouse, float p0) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            float2 v0;
            v0 = uv;
            float v1;
            float v2;
            float v3;
            v1 = float3(v0, 0.0).x;
            v2 = float3(v0, 0.0).y;
            v3 = float3(v0, 0.0).z;
            float3 v4;
            v4 = float3(v1, v2, p0);
            return half4(float4(v4, 1.0));
        }

        """
        #expect(s.exportSource == expected)
        #expect(s.functionName == "ripple")
        #expect(s.target == .stitchable(.colorEffect))
    }

    @Test func previewWrapsTheFunctionAndReadsUniforms() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        #expect(!s.source.contains("[[stitchable]]"))
        #expect(s.source.contains("half4 ripple(float2 position, half4 currentColor, float2 size, float time, float2 mouse, float p0)"))
        #expect(s.source.contains("float2 position = float2(in.uv.x, 1.0 - in.uv.y) * u.resolution;"))
        #expect(s.source.contains("half4 c = ripple(position, half4(0.0), u.resolution, u.time, u.mouse, u.p0);"))
        #expect(s.source.contains("return float4(c);"))
        #expect(s.source.contains("struct Uniforms"))
        #expect(s.fragmentFunctionName == "shaderMain")
    }

    @Test func distortionReturnsASourcePositionAndPreviewsTheField() throws {
        let s = try ShaderGenerator.generate(smallDocument(.distortionEffect), target: .stitchable(.distortionEffect))
        #expect(s.exportSource!.contains("[[stitchable]] float2 ripple(float2 position, float2 size, float time, float2 mouse, float p0)"))
        #expect(s.exportSource!.contains("return float2(float4(v4, 1.0).x, 1.0 - float4(v4, 1.0).y) * size;"))
        #expect(s.source.contains("float2 c = ripple(position, u.resolution, u.time, u.mouse, u.p0);"))
        #expect(s.source.contains("return float4(c / u.resolution, 0.0, 1.0);"))
    }

    @Test func layerEffectExportHasTheLayerAndThePreviewDoesNot() throws {
        let s = try ShaderGenerator.generate(smallDocument(.layerEffect), target: .stitchable(.layerEffect))
        #expect(s.exportSource!.contains("#include <SwiftUI/SwiftUI_Metal.h>"))
        #expect(s.exportSource!.contains("[[stitchable]] half4 ripple(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse, float p0)"))
        #expect(!s.source.contains("SwiftUI"))
        #expect(s.source.contains("half4 ripple(float2 position, float2 size, float time, float2 mouse, float p0)"))
    }

    @Test func unwiredOutputColorFallsBackToItsUniformDefault() throws {
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[out.id] = out
        let s = try ShaderGenerator.generate(d, target: .stitchable(.colorEffect))
        #expect(s.exportSource!.contains("float4 p0)"))
        #expect(s.exportSource!.contains("return half4(p0);"))
    }

    @Test func lineMapCoversTheStitchableBody() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        let line = s.source.components(separatedBy: "\n").firstIndex { $0.contains("v4 = float3(v1, v2, p0);") }! + 1
        #expect(s.lineMap.node(forLine: line) != nil)
    }
}
```

- [ ] **Step 2: Run to see them fail** (`--filter StitchableCodegenTests`).

- [ ] **Step 3: Implement**

`Codegen/StitchableCodegen.swift`:

```swift
import Foundation

/// Text pieces of a SwiftUI `[[stitchable]]` program (spec §9.5, §19.4).
public enum StitchableCodegen {
    public static let defaultName = "metalNodesShader"

    /// `raw` reduced to a C identifier; empty/blank → `defaultName`.
    public static func sanitizedName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return defaultName }
        var s = String(trimmed.unicodeScalars.map { ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "_") ? Character($0) : "_" })
        if let first = s.first, ("0"..."9").contains(first) { s = "_" + s }
        return s.isEmpty ? defaultName : s
    }

    public struct Argument: Sendable, Hashable {
        public let name: String
        public let mslType: String
        /// nil for `mouse`, which is not a layout slot.
        public let field: UniformField?
    }

    /// `float2 mouse`, then every user slot in layout order; int/bool travel as `float` (spec §19.2).
    public static func arguments(layout: UniformLayout) -> [Argument] {
        var out = [Argument(name: "mouse", mslType: "float2", field: nil)]
        for f in layout.fields where f.path != nil {
            let t: String = switch f.type {
            case .int, .bool: "float"
            default: f.type.mslName
            }
            out.append(Argument(name: f.name, mslType: t, field: f))
        }
        return out
    }

    static func signature(kind: StitchableKind, name: String, args: [Argument], forExport: Bool) -> String {
        let prefix: String = switch kind {
        case .colorEffect: "half4 \(name)(float2 position, half4 currentColor, float2 size, float time"
        case .distortionEffect: "float2 \(name)(float2 position, float2 size, float time"
        case .layerEffect: forExport
            ? "half4 \(name)(float2 position, SwiftUI::Layer layer, float2 size, float time"
            : "half4 \(name)(float2 position, float2 size, float time"
        }
        let tail = args.map { ", \($0.mslType) \($0.name)" }.joined()
        return (forExport ? "[[stitchable]] " : "") + prefix + tail + ")"
    }

    static func returnStatement(kind: StitchableKind, color: String) -> String {
        switch kind {
        case .colorEffect, .layerEffect: "return half4(\(color));"
        case .distortionEffect: "return float2(\(color).x, 1.0 - \(color).y) * size;"
        }
    }

    /// Body of the preview's `shaderMain`, calling the function with values read from `Uniforms`.
    static func previewBody(kind: StitchableKind, name: String, args: [Argument]) -> [String] {
        let call = args.map { a in a.field == nil ? "u.mouse" : "u.\(a.name)" }.joined(separator: ", ")
        var lines = ["float2 position = float2(in.uv.x, 1.0 - in.uv.y) * u.resolution;"]
        switch kind {
        case .colorEffect:
            lines.append("half4 c = \(name)(position, half4(0.0), u.resolution, u.time, \(call));")
            lines.append("return float4(c);")
        case .layerEffect:
            lines.append("half4 c = \(name)(position, u.resolution, u.time, \(call));")
            lines.append("return float4(c);")
        case .distortionEffect:
            lines.append("float2 c = \(name)(position, u.resolution, u.time, \(call));")
            lines.append("return float4(c / u.resolution, 0.0, 1.0);")
        }
        return lines
    }
}
```

Note: `u.pN` in the preview call passes the stored `int`/`bool` slots (declared `int` in `Uniforms`) to a `float` parameter — an implicit MSL conversion, which is what we want.

`ShaderGenerator.assembleStitchable`:

```swift
    private static func assembleStitchable(_ doc: ShaderDocument, kind: StitchableKind, order: [NodeID], terminal: NodeID,
                                           resolved: [NodeID: ResolvedNode], registry: NodeRegistry) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved, env: .stitchableFunction)
        let args = StitchableCodegen.arguments(layout: emitted.layout)
        let color = emitted.inputExpressions[terminal]?["color"] ?? "float4(0.0, 0.0, 0.0, 1.0)"
        let stdlib = MSLStdlib.resolve(emitted.requiredStdlib)

        func function(into b: inout SourceBuilder, forExport: Bool) {
            b.add(StitchableCodegen.signature(kind: kind, name: name, args: args, forExport: forExport) + " {")
            b.add("    float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);")
            for (i, line) in emitted.bodyLines.enumerated() where emitted.lineOwners[i] != terminal {
                b.add("    " + line, owner: emitted.lineOwners[i])
            }
            b.add("    " + StitchableCodegen.returnStatement(kind: kind, color: color), owner: terminal)
            b.add("}")
        }

        var export = SourceBuilder()
        export.add("#include <metal_stdlib>" + (kind == .layerEffect ? "\n#include <SwiftUI/SwiftUI_Metal.h>" : "") + "\nusing namespace metal;\n")
        for f in stdlib { export.add(f.source + "\n") }
        function(into: &export, forExport: true)

        var preview = SourceBuilder()
        preview.add("#include <metal_stdlib>\nusing namespace metal;\n")
        preview.add(emitted.layout.mslStruct + "\n")
        preview.add("struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n")
        for f in stdlib { preview.add(f.source + "\n") }
        function(into: &preview, forExport: false)
        preview.add("")
        preview.add("fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n                           constant Uniforms &u [[buffer(0)]]) {")
        for l in StitchableCodegen.previewBody(kind: kind, name: name, args: args) { preview.add("    " + l) }
        preview.add("}")

        return GeneratedShader(source: preview.text, layout: emitted.layout, lineMap: preview.map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: .stitchable(kind),
                               viewer: nil, exportSource: export.text, functionName: name)
    }
```

The `Fragment Output`'s own `return {in.color};` line is dropped (owner == terminal) and replaced by the kind's return; its unwired `color` default still claims a uniform slot through the normal request pass, which is what the last test asserts.

- [ ] **Step 4: Run** `swift test --package-path MetalNodesKit` — green (fix the golden text to the exact produced output only if a whitespace detail differs *and* the produced output matches §19.4; never loosen it).

- [ ] **Step 5: Commit** — `feat(core): stitchable target — colorEffect/distortionEffect/layerEffect functions, preview wrapper, export source`

---

### Task 5: Shader export (files + Swift snippet)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Export/ShaderExport.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ShaderExportTests.swift`

**Interfaces:**
- Produces: `ExportFile { name, contents }`; `ShaderExport.files(for:registry:) throws(GenerationError) -> [ExportFile]`; `ShaderExport.swiftSnippet(for: GeneratedShader, kind:, document:, registry:) -> String`; `ShaderExport.parameterNames(for:document:registry:) -> [String]`.
- Consumes: T4.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct ShaderExportTests {
    private func doc(_ kind: StitchableKind) -> ShaderDocument {
        // Float "Speed" (int-free), Integer, Boolean → all feed nothing; Output unwired → four slots.
        var d = ShaderDocument()
        let f = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(2)], customTitle: "Speed")
        let out = NodeInstance(kind: .builtin("output.fragment"))
        let m = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        d.root.nodes[f.id] = f; d.root.nodes[out.id] = out; d.root.nodes[m.id] = m
        d.root.connect(SocketRef(f.id, "out"), to: SocketRef(m.id, "a"))
        d.root.connect(SocketRef(m.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(kind); d.settings.exportName = "glow"
        return d
    }

    @Test func stitchableExportProducesMetalAndSwift() throws {
        let files = try ShaderExport.files(for: doc(.colorEffect))
        #expect(files.map(\.name) == ["glow.metal", "glow.swift"])
        #expect(files[0].contents.contains("[[stitchable]] half4 glow("))
        #expect(files[1].contents.contains("extension View"))
    }

    @Test func fragmentExportIsJustTheMetalFile() throws {
        var d = ShaderDocument.sample(); d.settings.exportName = "sample"
        let files = try ShaderExport.files(for: d)
        #expect(files.map(\.name) == ["sample.metal"])
        #expect(files[0].contents.contains("fragment float4 shaderMain"))
    }

    @Test func parameterNamesComeFromNodeTitleAndLabelAndDeduplicate() throws {
        let d = doc(.colorEffect)
        let s = try ShaderGenerator.generate(d, target: d.settings.target)
        let args = StitchableCodegen.arguments(layout: s.layout)
        let names = ShaderExport.parameterNames(for: args, document: d, registry: .builtin)
        // mouse, then (alignment-sorted) slots: Speed·Value and Math·B (the unwired generic input);
        // the Output's color is wired, so it claims no slot.
        #expect(names == ["mouse", "speedValue", "mathB"])
    }

    @Test func swiftSnippetGoldenForColorEffect() throws {
        var d = ShaderDocument()
        let i = NodeInstance(kind: .builtin("input.int"), params: ["value": .int(3)])
        let b = NodeInstance(kind: .builtin("input.bool"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        d.root.nodes[i.id] = i; d.root.nodes[b.id] = b; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(i.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.colorEffect); d.settings.exportName = "glow"
        let s = try ShaderGenerator.generate(d, target: d.settings.target)
        let snippet = ShaderExport.swiftSnippet(for: s, kind: .colorEffect, document: d, registry: .builtin)
        let expected = """
        // glow.swift — generated by MetalNodes. Argument order matches glow.metal.
        import SwiftUI

        extension View {
            /// Applies the MetalNodes shader "glow".
            func glow(size: CGSize, time: Float, mouse: CGPoint, integerValue: Int) -> some View {
                colorEffect(ShaderLibrary.glow(
                    .float2(size),
                    .float(time),
                    .float2(mouse),
                    .float(Float(integerValue))    // Integer · Value
                ))
            }
        }

        """
        #expect(snippet == expected)
    }

    @Test func distortionAndLayerSnippetsPassMaxSampleOffset() throws {
        let d = doc(.distortionEffect)
        let s = try ShaderGenerator.generate(d, target: d.settings.target)
        let snippet = ShaderExport.swiftSnippet(for: s, kind: .distortionEffect, document: d, registry: .builtin)
        #expect(snippet.contains("distortionEffect(ShaderLibrary.glow("))
        #expect(snippet.contains("), maxSampleOffset: .zero)"))
        let l = ShaderExport.swiftSnippet(for: s, kind: .layerEffect, document: d, registry: .builtin)
        #expect(l.contains("layerEffect(ShaderLibrary.glow("))
    }

    @Test func boolAndColorArgumentsAreConverted() throws {
        var d = ShaderDocument()
        let b = NodeInstance(kind: .builtin("input.bool")), c = NodeInstance(kind: .builtin("input.color"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        let sw = NodeInstance(kind: .builtin("utility.switch"))
        for n in [b, c, out, sw] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(b.id, "out"), to: SocketRef(sw.id, "cond"))
        d.root.connect(SocketRef(c.id, "out"), to: SocketRef(sw.id, "a"))
        d.root.connect(SocketRef(sw.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.colorEffect)
        let s = try ShaderGenerator.generate(d, target: d.settings.target)
        let snippet = ShaderExport.swiftSnippet(for: s, kind: .colorEffect, document: d, registry: .builtin)
        #expect(snippet.contains("booleanValue: Bool"))
        #expect(snippet.contains(".float(booleanValue ? 1 : 0)"))
        #expect(snippet.contains("colorValue: Color"))
        #expect(snippet.contains(".color(colorValue)"))
    }

    /// The export must be a valid Metal file. `[[stitchable]]` is not exercised by the runtime
    /// compiler, so use the toolchain when it is installed; skip silently otherwise.
    @Test func exportedMetalCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        for kind in StitchableKind.allCases {
            let files = try ShaderExport.files(for: doc(kind))
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-export-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(files[0].name)
            try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
            let metal = Process()
            metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
            let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
            try metal.run(); metal.waitUntilExit()
            let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(metal.terminationStatus == 0, "\(kind): \(log)")
        }
    }
}
```

Note: `utility.switch`, `input.int`, `input.bool` arrive in T6/T8; write these tests now, they compile (ids are strings) and fail until the library lands — mark the two that need them with `.disabled("needs T6/T8")` traits and re-enable in T8's Step 4. `parameterNamesComeFrom…` also needs the Math default slot: unwired `b` on Math takes a uniform (already true in M2).

- [ ] **Step 2: Run to see them fail** (`--filter ShaderExportTests`).

- [ ] **Step 3: Implement**

```swift
import Foundation

public struct ExportFile: Sendable, Hashable {
    public let name: String
    public let contents: String
    public init(name: String, contents: String) { self.name = name; self.contents = contents }
}

/// What File ▸ Export Shader… writes (spec §9.5, §19.4).
public enum ShaderExport {
    public static func files(for doc: ShaderDocument, registry: NodeRegistry = .builtin) throws(GenerationError) -> [ExportFile] {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let shader = try ShaderGenerator.generate(doc, target: doc.settings.target, viewer: nil, registry: registry)
        guard let kind = doc.settings.target.stitchableKind, let export = shader.exportSource else {
            return [ExportFile(name: "\(name).metal", contents: shader.source)]
        }
        return [ExportFile(name: "\(name).metal", contents: export),
                ExportFile(name: "\(name).swift", contents: swiftSnippet(for: shader, kind: kind, document: doc, registry: registry))]
    }

    /// Swift parameter names: `mouse`, then camelCase(node title + param label), de-duplicated with a numeric suffix.
    public static func parameterNames(for args: [StitchableCodegen.Argument], document: ShaderDocument, registry: NodeRegistry) -> [String] {
        var used = Set<String>(), out: [String] = []
        for a in args {
            var base = "mouse"
            if let f = a.field, let path = f.path, let nodeID = path.instancePath.first,
               let node = document.root.nodes[nodeID], case .builtin(let defID) = node.kind, let def = registry[defID] {
                let title = node.customTitle ?? def.title
                let label = def.input(named: path.param)?.label ?? def.param(named: path.param)?.label ?? path.param
                base = camelCase(title + " " + label)
            } else if a.field != nil {
                base = a.name
            }
            var name = base, n = 2
            while used.contains(name) { name = base + "\(n)"; n += 1 }
            used.insert(name); out.append(name)
        }
        return out
    }

    static func camelCase(_ s: String) -> String {
        let words = s.split { !$0.isLetter && !$0.isNumber }.map { String($0) }
        guard let first = words.first else { return "value" }
        let rest = words.dropFirst().map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
        var out = first.lowercased() + rest.joined()
        if let c = out.first, c.isNumber { out = "_" + out }
        return out
    }

    public static func swiftSnippet(for shader: GeneratedShader, kind: StitchableKind, document: ShaderDocument, registry: NodeRegistry) -> String {
        let name = shader.functionName
        let args = StitchableCodegen.arguments(layout: shader.layout)
        let names = parameterNames(for: args, document: document, registry: registry)
        var params: [String] = ["size: CGSize", "time: Float"]
        var calls: [(call: String, comment: String)] = [(".float2(size)", ""), (".float(time)", "")]
        for (a, n) in zip(args, names) {
            guard let f = a.field else { params.append("\(n): CGPoint"); calls.append((".float2(\(n))", "")); continue }
            let comment = "    // " + commentLabel(for: f, document: document, registry: registry)
            switch f.type {
            case .float: params.append("\(n): Float"); calls.append((".float(\(n))", comment))
            case .float2: params.append("\(n): SIMD2<Float>"); calls.append((".float2(\(n))", comment))
            case .float3: params.append("\(n): SIMD3<Float>"); calls.append((".float3(\(n))", comment))
            case .float4: params.append("\(n): SIMD4<Float>"); calls.append((".float4(\(n))", comment))
            case .color: params.append("\(n): Color"); calls.append((".color(\(n))", comment))
            case .int: params.append("\(n): Int"); calls.append((".float(Float(\(n)))", comment))
            case .bool: params.append("\(n): Bool"); calls.append((".float(\(n) ? 1 : 0)", comment))
            case .texture: continue
            }
        }
        // The comma goes before the comment — a trailing comment must never swallow it.
        let argumentLines = calls.enumerated().map { i, c in
            "            " + c.call + (i == calls.count - 1 ? "" : ",") + c.comment
        }
        let modifier: String = switch kind {
        case .colorEffect: "colorEffect"
        case .distortionEffect: "distortionEffect"
        case .layerEffect: "layerEffect"
        }
        let tail = kind == .colorEffect ? "))" : "), maxSampleOffset: .zero)"
        var s = "// \(name).swift — generated by MetalNodes. Argument order matches \(name).metal.\n"
        s += "import SwiftUI\n\nextension View {\n"
        s += "    /// Applies the MetalNodes shader \"\(name)\".\n"
        s += "    func \(name)(\(params.joined(separator: ", "))) -> some View {\n"
        s += "        \(modifier)(ShaderLibrary.\(name)(\n"
        s += argumentLines.joined(separator: "\n") + "\n"
        s += "        \(tail)\n    }\n}\n"
        return s
    }

    private static func commentLabel(for f: UniformField, document: ShaderDocument, registry: NodeRegistry) -> String {
        guard let path = f.path, let nodeID = path.instancePath.first, let node = document.root.nodes[nodeID],
              case .builtin(let defID) = node.kind, let def = registry[defID] else { return f.name }
        let label = def.input(named: path.param)?.label ?? def.param(named: path.param)?.label ?? path.param
        return "\(node.customTitle ?? def.title) · \(label)"
    }
}
```

Every argument line except the last ends with a comma placed *before* its comment (`.float(a),    // Node · Label`); the golden's last line carries no comma. Match the golden exactly; adjust it only to what §19.4 shows.

- [ ] **Step 4: Run** `swift test --package-path MetalNodesKit --filter ShaderExportTests` — the disabled two stay skipped; the rest green. Then the full suite.

- [ ] **Step 5: Commit** — `feat(core): ShaderExport — .metal + .swift files with a ShaderLibrary snippet in argument order`

---

### Task 6: Library — Input, Math, Vector nodes

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/InputNodes.swift`, `MathNodes.swift`, `VectorNodes.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Stdlib/VectorStdlib.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift` (becomes `all = input + math + vector + noise + output` — SDF/Color/Utility join in T7/T8), `Library/MSLStdlib.swift` (table = `core + vector + …`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/LibraryM3Tests.swift`, `BuiltinLibraryTests.swift` (expected id set), `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift`

**Interfaces:**
- Produces: node ids `input.float2`, `input.float3`, `input.int`, `input.bool`, `input.mouse`, `math.clamp`, `math.step`, `math.maprange`, `vector.dot`, `vector.normalize`, `vector.rotate2d`; stdlib `rotate2d`.
- Consumes: T1 (`{sys.mouse}`).

- [ ] **Step 1: Write the failing tests**

`LibraryM3Tests.swift` (grows in T7/T8):

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct LibraryM3Tests {
    let reg = NodeRegistry.builtin

    /// Every node as a one-node graph (first output → Fragment Output) generates without diagnostics.
    @Test func everyNodeGeneratesAsAOneNodeGraph() throws {
        for def in reg.all where def.id != "output.fragment" {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            if let first = def.outputs.first { doc.root.connect(SocketRef(n.id, first.name), to: SocketRef(out.id, "color")) }
            let s = try ShaderGenerator.generate(doc, registry: reg)
            #expect(!s.source.contains("/* ?"), def.id)
            #expect(!s.source.contains("/* unconnected */"), def.id)
        }
    }

    @Test func inputConstantsCoverEveryUniformableType() {
        #expect(reg["input.float2"]?.outputs.first?.type == .concrete(.float2))
        #expect(reg["input.float3"]?.outputs.first?.type == .concrete(.float3))
        #expect(reg["input.int"]?.outputs.first?.type == .concrete(.int))
        #expect(reg["input.bool"]?.outputs.first?.type == .concrete(.bool))
        #expect(reg["input.mouse"]?.outputs.first?.name == "position")
    }

    @Test func mouseReadsTheSystemValue() throws {
        let m = NodeInstance(kind: .builtin("input.mouse")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[m.id] = m; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(m.id, "position"), to: SocketRef(out.id, "color"))
        #expect(try ShaderGenerator.generate(d).source.contains("v0 = u.mouse;"))
        d.settings.target = .stitchable(.colorEffect)
        #expect(try ShaderGenerator.generate(d, target: d.settings.target).exportSource!.contains("v0 = mouse;"))
    }

    @Test func mapRangeCastsScalarEdgesToTheGenericType() throws {
        let v = NodeInstance(kind: .builtin("vector.combine")), mr = NodeInstance(kind: .builtin("math.maprange"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [v, mr, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(v.id, "out"), to: SocketRef(mr.id, "value"))
        d.root.connect(SocketRef(mr.id, "out"), to: SocketRef(out.id, "color"))
        let src = try ShaderGenerator.generate(d).source
        #expect(src.contains("float3(u.p"))          // edges are cast to float3
    }

    @Test func rotate2dGoesThroughTheStdlib() throws {
        let def = try #require(reg["vector.rotate2d"])
        #expect(def.requires == ["rotate2d"])
        #expect(MSLStdlib.functions["rotate2d"]?.source.contains("float2 mn_rotate2d(float2 v, float angle, float2 center)") == true)
    }
}
```

`BuiltinLibraryTests.registryContainsTheM1Set` → rename to `registryContainsTheV1Set`, expected set = the 13 M1 ids + the 11 of this task (T7 and T8 each extend it). Also change `everyRequiredStdlibFunctionExists` — unchanged, it already loops.

`ShaderCompilerTests.everyMathVariantCompiles` → generalise to `everyVariantOfEveryVariantsNodeCompiles`: loop `for def in NodeRegistry.builtin.all`, `guard case .variants(let param, let table) = def.body`, for each case build the one-node graph with `params: [param: .enumCase(op)]`, and `Issue.record` on failure. Add:

```swift
    @Test func everyViewableTypeCompilesAsAViewerProgram() async throws {
        let c = try compiler()
        for (def, socket) in [("input.float", "out"), ("input.float2", "out"), ("input.float3", "out"), ("input.color", "out"),
                              ("input.int", "out"), ("input.bool", "out")] {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def)), out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            let shader = try ShaderGenerator.generate(doc, viewer: SocketRef(n.id, socket))
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(def) viewer failed: \(msg)\n\(shader.source)") }
        }
    }

    @Test func everyStitchableKindPreviewCompiles() async throws {
        let c = try compiler()
        for kind in StitchableKind.allCases {
            var doc = ShaderDocument.sample()
            doc.settings.target = .stitchable(kind)
            let shader = try ShaderGenerator.generate(doc, target: doc.settings.target)
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(kind) preview failed: \(msg)\n\(shader.source)") }
        }
    }
```

- [ ] **Step 2: Run to see them fail** (`--filter "LibraryM3Tests|BuiltinLibraryTests"`).

- [ ] **Step 3: Implement**

`Library/Builtin/InputNodes.swift`:

```swift
import Foundation

extension BuiltinNodes {
    static let input: [NodeDef] = [
        NodeDef(id: "input.uv", title: "UV", category: .input,
                outputs: [SocketDecl(name: "uv", type: .concrete(.float2))],
                params: [ParamDecl(name: "mode", kind: .enumeration(["normalized", "aspect"]), defaultValue: .enumCase("normalized"))],
                body: .variants(param: "mode", [
                    "normalized": "{out.uv} = {sys.uv};",
                    "aspect": "{out.uv} = ({sys.uv} - 0.5) * ({sys.resolution} / {sys.resolution}.y);",
                ])),
        NodeDef(id: "input.time", title: "Time", category: .input,
                outputs: [SocketDecl(name: "time", type: .concrete(.float))],
                body: .template("{out.time} = {sys.time};")),
        NodeDef(id: "input.resolution", title: "Resolution", category: .input,
                outputs: [SocketDecl(name: "resolution", type: .concrete(.float2))],
                body: .template("{out.resolution} = {sys.resolution};")),
        NodeDef(id: "input.mouse", title: "Mouse", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float2))],
                body: .template("{out.position} = {sys.mouse};")),
        NodeDef(id: "input.float", title: "Float", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                params: [ParamDecl(name: "value", kind: .value(.float, range: -10...10), defaultValue: .float(1))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.float2", title: "Vector 2", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.float2))],
                params: [ParamDecl(name: "value", kind: .value(.float2, range: -10...10), defaultValue: .float2(.init(0, 0)))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.float3", title: "Vector 3", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.float3))],
                params: [ParamDecl(name: "value", kind: .value(.float3, range: -10...10), defaultValue: .float3(.init(0, 0, 0)))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.color", title: "Color", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                params: [ParamDecl(name: "value", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.int", title: "Integer", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.int))],
                params: [ParamDecl(name: "value", kind: .value(.int, range: 0...100), defaultValue: .int(1))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.bool", title: "Boolean", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.bool))],
                params: [ParamDecl(name: "value", kind: .value(.bool, range: nil), defaultValue: .bool(true))],
                body: .template("{out.out} = {param.value};")),
    ]
}
```

`Library/Builtin/MathNodes.swift` — the three existing math nodes moved verbatim, plus:

```swift
        NodeDef(id: "math.clamp", title: "Clamp", category: .math,
                inputs: [SocketDecl(name: "x", type: .generic("T"), default: .value(.float(0.5)), range: -10...10),
                         SocketDecl(name: "min", label: "Min", type: .concrete(.float), default: .value(.float(0)), range: -10...10),
                         SocketDecl(name: "max", label: "Max", type: .concrete(.float), default: .value(.float(1)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = clamp({in.x}, {type.T}({in.min}), {type.T}({in.max}));")),
        NodeDef(id: "math.step", title: "Step", category: .math,
                inputs: [SocketDecl(name: "edge", type: .concrete(.float), default: .value(.float(0.5)), range: -1...2),
                         SocketDecl(name: "x", type: .generic("T"), default: .value(.float(0)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = step({type.T}({in.edge}), {in.x});")),
        NodeDef(id: "math.maprange", title: "Map Range", category: .math,
                inputs: [SocketDecl(name: "value", type: .generic("T"), default: .value(.float(0.5)), range: -10...10),
                         SocketDecl(name: "fromMin", label: "From Min", type: .concrete(.float), default: .value(.float(0)), range: -10...10),
                         SocketDecl(name: "fromMax", label: "From Max", type: .concrete(.float), default: .value(.float(1)), range: -10...10),
                         SocketDecl(name: "toMin", label: "To Min", type: .concrete(.float), default: .value(.float(0)), range: -10...10),
                         SocketDecl(name: "toMax", label: "To Max", type: .concrete(.float), default: .value(.float(1)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = {type.T}({in.toMin}) + ({in.value} - {type.T}({in.fromMin})) * ({type.T}({in.toMax}) - {type.T}({in.toMin})) / max({type.T}({in.fromMax}) - {type.T}({in.fromMin}), {type.T}(1e-6));")),
```

`Library/Builtin/VectorNodes.swift` — the three existing vector nodes moved verbatim, plus:

```swift
        NodeDef(id: "vector.dot", title: "Dot", category: .vector,
                inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(1)), range: -10...10),
                         SocketDecl(name: "b", type: .generic("T"), default: .value(.float(1)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                generics: ["T": anyVector],
                body: .template("{out.out} = dot({in.a}, {in.b});")),
        NodeDef(id: "vector.normalize", title: "Normalize", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .generic("T"), default: .value(.float(1)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyVector],
                body: .template("{out.out} = normalize({in.v});")),
        NodeDef(id: "vector.rotate2d", title: "Rotate 2D", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "angle", type: .concrete(.float), default: .value(.float(0)), range: -3.1416...3.1416),
                         SocketDecl(name: "center", type: .concrete(.float2), default: .value(.float2(.init(0.5, 0.5))), range: -1...2)],
                outputs: [SocketDecl(name: "out", type: .concrete(.float2))],
                requires: ["rotate2d"],
                body: .template("{out.out} = mn_rotate2d({in.v}, {in.angle}, {in.center});")),
```

`Library/Stdlib/VectorStdlib.swift`:

```swift
import Foundation

extension MSLStdlib {
    static let vector: [MSLFunction] = [
        MSLFunction(name: "rotate2d", dependencies: [], source: """
        float2 mn_rotate2d(float2 v, float angle, float2 center) {
            float s = sin(angle), c = cos(angle);
            float2 d = v - center;
            return float2(c * d.x - s * d.y, s * d.x + c * d.y) + center;
        }
        """),
    ]
}
```

`MSLStdlib.swift`: rename the private `all` to `static let core` (hash21, valueNoise) and define `private static let all: [MSLFunction] = core + vector` (T7 adds `+ sdf + noise`, T8 `+ color`). `BuiltinNodes.all = input + math + vector + noise + output` where `noise`/`output` hold the existing Value Noise and Fragment Output definitions (moved into `NoiseNodes.swift` in T7; until then keep them inline in `BuiltinNodes.swift`).

- [ ] **Step 4: Run** the full suite; the Render smoke tests (`everyBuiltinNodeCompilesAsAOneNodeGraph`, the generalised variants test) need a GPU — run them locally: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests`.

- [ ] **Step 5: Commit** — `feat(core): library — Vector 2/3, Integer, Boolean, Mouse, Clamp, Step, Map Range, Dot, Normalize, Rotate 2D`

---

### Task 7: Library — SDF and Noise nodes

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/SDFNodes.swift`, `NoiseNodes.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Stdlib/SDFStdlib.swift`, `NoiseStdlib.swift`
- Modify: `BuiltinNodes.swift`, `MSLStdlib.swift`
- Test: `LibraryM3Tests.swift`, `BuiltinLibraryTests.swift`

**Interfaces:**
- Produces: `sdf.circle`, `sdf.box`, `sdf.union`, `sdf.subtract`, `noise.perlin`, `noise.simplex`, `noise.voronoi`, `noise.fbm`; stdlib `sdBox`, `hash22`, `perlin`, `simplex` (+ `mod289_2`, `mod289_3`, `permute3`), `voronoi`, `fbm`.

- [ ] **Step 1: Write the failing tests** (append to `LibraryM3Tests`)

```swift
    @Test func sdfAndNoiseNodesExistWithFloatOutputs() {
        for id in ["sdf.circle", "sdf.box", "sdf.union", "sdf.subtract", "noise.perlin", "noise.simplex", "noise.voronoi", "noise.fbm"] {
            #expect(reg[id]?.outputs.first?.type == .concrete(.float), id)
        }
        #expect(reg["sdf.circle"]?.category == .sdf)
    }

    @Test func fbmOctavesIsAnIntUniformReadInsideTheLoop() throws {
        let f = NodeInstance(kind: .builtin("noise.fbm")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[f.id] = f; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(f.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.layout.field(for: ParamPath(node: f.id, param: "octaves"))?.type == .int)
        #expect(s.source.contains("mn_fbm(in.uv * u.p"))
        #expect(s.source.contains("float mn_fbm(float2 p, int octaves)"))
        #expect(MSLStdlib.resolve(["fbm"]).map(\.name) == ["hash21", "valueNoise", "fbm"])
    }

    @Test func stdlibDependenciesResolveForEveryNoise() {
        #expect(MSLStdlib.resolve(["perlin"]).map(\.name) == ["hash22", "perlin"])
        #expect(MSLStdlib.resolve(["voronoi"]).map(\.name) == ["hash22", "voronoi"])
        #expect(MSLStdlib.resolve(["simplex"]).map(\.name) == ["mod289_2", "mod289_3", "permute3", "simplex"])
    }
```

Extend `registryContainsTheV1Set` with the eight ids.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`Library/Builtin/SDFNodes.swift`:

```swift
import Foundation

extension BuiltinNodes {
    static let sdf: [NodeDef] = [
        NodeDef(id: "sdf.circle", title: "Circle", category: .sdf,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "center", type: .concrete(.float2), default: .value(.float2(.init(0.5, 0.5))), range: -1...2),
                         SocketDecl(name: "radius", type: .concrete(.float), default: .value(.float(0.25)), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = length({in.uv} - {in.center}) - {in.radius};")),
        NodeDef(id: "sdf.box", title: "Box", category: .sdf,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "center", type: .concrete(.float2), default: .value(.float2(.init(0.5, 0.5))), range: -1...2),
                         SocketDecl(name: "size", type: .concrete(.float2), default: .value(.float2(.init(0.25, 0.25))), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                requires: ["sdBox"],
                body: .template("{out.out} = mn_sdBox({in.uv} - {in.center}, {in.size});")),
        NodeDef(id: "sdf.union", title: "Union", category: .sdf,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)), range: -1...1),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(1)), range: -1...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = min({in.a}, {in.b});")),
        NodeDef(id: "sdf.subtract", title: "Subtract", category: .sdf,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)), range: -1...1),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(1)), range: -1...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = max({in.a}, -{in.b});")),
    ]
}
```

`Library/Builtin/NoiseNodes.swift` — Value Noise moved verbatim, plus:

```swift
        NodeDef(id: "noise.perlin", title: "Perlin Noise", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)), range: 0.1...32)],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                requires: ["perlin"],
                body: .template("{out.out} = mn_perlin({in.uv} * {in.scale});")),
        NodeDef(id: "noise.simplex", title: "Simplex Noise", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)), range: 0.1...32)],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                requires: ["simplex"],
                body: .template("{out.out} = mn_simplex({in.uv} * {in.scale});")),
        NodeDef(id: "noise.voronoi", title: "Voronoi", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)), range: 0.1...32)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                requires: ["voronoi"],
                body: .template("{out.out} = mn_voronoi({in.uv} * {in.scale});")),
        NodeDef(id: "noise.fbm", title: "Fbm", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)), range: 0.1...32)],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                params: [ParamDecl(name: "octaves", kind: .value(.int, range: 1...8), defaultValue: .int(5))],
                requires: ["fbm"],
                body: .template("{out.out} = mn_fbm({in.uv} * {in.scale}, {param.octaves});")),
```

`Library/Stdlib/SDFStdlib.swift`:

```swift
extension MSLStdlib {
    static let sdf: [MSLFunction] = [
        MSLFunction(name: "sdBox", dependencies: [], source: """
        float mn_sdBox(float2 p, float2 b) {
            float2 d = abs(p) - b;
            return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
        }
        """),
    ]
}
```

`Library/Stdlib/NoiseStdlib.swift`:

```swift
extension MSLStdlib {
    static let noise: [MSLFunction] = [
        MSLFunction(name: "hash22", dependencies: [], source: """
        float2 mn_hash22(float2 p) {
            float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.xx + p3.yz) * p3.zy);
        }
        """),
        MSLFunction(name: "perlin", dependencies: ["hash22"], source: """
        float mn_perlin(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 u = f * f * (3.0 - 2.0 * f);
            float2 g00 = mn_hash22(i) * 2.0 - 1.0;
            float2 g10 = mn_hash22(i + float2(1.0, 0.0)) * 2.0 - 1.0;
            float2 g01 = mn_hash22(i + float2(0.0, 1.0)) * 2.0 - 1.0;
            float2 g11 = mn_hash22(i + float2(1.0, 1.0)) * 2.0 - 1.0;
            float n = mix(mix(dot(g00, f), dot(g10, f - float2(1.0, 0.0)), u.x),
                          mix(dot(g01, f - float2(0.0, 1.0)), dot(g11, f - float2(1.0, 1.0)), u.x), u.y);
            return saturate(n * 0.7 + 0.5);
        }
        """),
        MSLFunction(name: "mod289_2", dependencies: [], source: """
        float2 mn_mod289_2(float2 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        """),
        MSLFunction(name: "mod289_3", dependencies: [], source: """
        float3 mn_mod289_3(float3 x) { return x - floor(x * (1.0 / 289.0)) * 289.0; }
        """),
        MSLFunction(name: "permute3", dependencies: ["mod289_3"], source: """
        float3 mn_permute3(float3 x) { return mn_mod289_3(((x * 34.0) + 1.0) * x); }
        """),
        MSLFunction(name: "simplex", dependencies: ["mod289_2", "mod289_3", "permute3"], source: """
        float mn_simplex(float2 v) {
            const float4 C = float4(0.211324865405187, 0.366025403784439, -0.577350269189626, 0.024390243902439);
            float2 i = floor(v + dot(v, C.yy));
            float2 x0 = v - i + dot(i, C.xx);
            float2 i1 = (x0.x > x0.y) ? float2(1.0, 0.0) : float2(0.0, 1.0);
            float4 x12 = x0.xyxy + C.xxzz;
            x12.xy -= i1;
            i = mn_mod289_2(i);
            float3 p = mn_permute3(mn_permute3(i.y + float3(0.0, i1.y, 1.0)) + i.x + float3(0.0, i1.x, 1.0));
            float3 m = max(0.5 - float3(dot(x0, x0), dot(x12.xy, x12.xy), dot(x12.zw, x12.zw)), 0.0);
            m = m * m;
            m = m * m;
            float3 x = 2.0 * fract(p * C.www) - 1.0;
            float3 h = abs(x) - 0.5;
            float3 ox = floor(x + 0.5);
            float3 a0 = x - ox;
            m *= 1.79284291400159 - 0.85373472095314 * (a0 * a0 + h * h);
            float3 g;
            g.x = a0.x * x0.x + h.x * x0.y;
            g.yz = a0.yz * x12.xz + h.yz * x12.yw;
            return saturate(130.0 * dot(m, g) * 0.5 + 0.5);
        }
        """),
        MSLFunction(name: "voronoi", dependencies: ["hash22"], source: """
        float mn_voronoi(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float d = 8.0;
            for (int y = -1; y <= 1; y++) {
                for (int x = -1; x <= 1; x++) {
                    float2 g = float2(x, y);
                    float2 r = g + mn_hash22(i + g) - f;
                    d = min(d, dot(r, r));
                }
            }
            return sqrt(d);
        }
        """),
        MSLFunction(name: "fbm", dependencies: ["valueNoise"], source: """
        float mn_fbm(float2 p, int octaves) {
            float v = 0.0;
            float a = 0.5;
            for (int i = 0; i < octaves; i++) {
                v += a * mn_valueNoise(p);
                p *= 2.0;
                a *= 0.5;
            }
            return v;
        }
        """),
    ]
}
```

`MSLStdlib.all = core + vector + sdf + noise`; `BuiltinNodes.all = input + math + vector + sdf + noise + output`.

- [ ] **Step 4: Run** the full suite plus `--filter ShaderCompilerTests` on the GPU (every new node and every viewer type must compile — the noise functions are the risk; fix MSL typos here, never by loosening tests).

- [ ] **Step 5: Commit** — `feat(core): library — SDF (circle, box, union, subtract) and noise (perlin, simplex, voronoi, fbm)`

---

### Task 8: Library — Color and Utility nodes

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/ColorNodes.swift`, `UtilityNodes.swift`, `Library/Stdlib/ColorStdlib.swift`
- Modify: `BuiltinNodes.swift`, `MSLStdlib.swift`, `Library/SampleDocuments.swift` (no change to the sample graph — only if a test needs it)
- Test: `LibraryM3Tests.swift`, `BuiltinLibraryTests.swift`; re-enable the two `ShaderExportTests`

**Interfaces:**
- Produces: `color.ramp`, `color.hsv2rgb`, `color.rgb2hsv`, `color.invert`, `color.mixcolor`, `utility.reroute` (`style: .dot`), `utility.compare`, `utility.switch`; stdlib `rampSegment`, `ramp3`, `ramp4`, `hsv2rgb`, `rgb2hsv`. Registry total **40**.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func registryHasTheFullV1Set() {
        #expect(reg.all.count == 40)
        for c in NodeCategory.allCases { #expect(reg.all.contains { $0.category == c }, "\(c)") }
    }

    @Test func colorRampOnlyClaimsSlotsForItsChosenStopCount() throws {
        func slots(_ stops: String) throws -> Int {
            let r = NodeInstance(kind: .builtin("color.ramp"), params: ["stops": .enumCase(stops)])
            let out = NodeInstance(kind: .builtin("output.fragment"))
            var d = ShaderDocument(); d.root.nodes[r.id] = r; d.root.nodes[out.id] = out
            d.root.connect(SocketRef(r.id, "out"), to: SocketRef(out.id, "color"))
            return try ShaderGenerator.generate(d).layout.fields.filter { $0.path?.instancePath.first == r.id }.count
        }
        #expect(try slots("2") == 3)     // fac, col0, col1
        #expect(try slots("3") == 5)     // fac, col0, pos1, col1, col2
        #expect(try slots("4") == 7)     // fac, col0, pos1, col1, pos2, col2, col3
    }

    @Test func rampStopControlsAreHiddenFromTheBody() throws {
        let def = try #require(reg["color.ramp"])
        #expect(def.params.filter(\.showsInBody).map(\.name) == ["stops"])
        #expect(def.params.count == 7)
    }

    @Test func rerouteIsADotAndKeepsAnExactType() throws {
        let def = try #require(reg["utility.reroute"])
        #expect(def.style == .dot)
        let c = NodeInstance(kind: .builtin("input.color")), r = NodeInstance(kind: .builtin("utility.reroute"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [c, r, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(c.id, "out"), to: SocketRef(r.id, "in"))
        d.root.connect(SocketRef(r.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.resolved[r.id]?.outputTypes["out"] == .color)
    }

    @Test func compareProducesBoolAndSwitchSelects() throws {
        let cmp = NodeInstance(kind: .builtin("utility.compare"), params: ["op": .enumCase("greater")])
        let sw = NodeInstance(kind: .builtin("utility.switch")), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); for n in [cmp, sw, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(cmp.id, "out"), to: SocketRef(sw.id, "cond"))
        d.root.connect(SocketRef(sw.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(d)
        #expect(s.resolved[cmp.id]?.outputTypes["out"] == .bool)
        #expect(s.source.contains(" > "))
        #expect(s.source.contains(" ? "))
    }
```

Extend `registryContainsTheV1Set` with the eight ids (total 40). Remove the `.disabled` traits from the two `ShaderExportTests`.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`Library/Builtin/ColorNodes.swift`:

```swift
import Foundation

extension BuiltinNodes {
    static let color: [NodeDef] = [
        NodeDef(id: "color.ramp", title: "Color Ramp", category: .color,
                inputs: [SocketDecl(name: "fac", label: "Factor", type: .concrete(.float), default: .value(.float(0.5)), range: 0...1)],
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                params: [ParamDecl(name: "stops", kind: .enumeration(["2", "3", "4"]), defaultValue: .enumCase("2")),
                         ParamDecl(name: "col0", label: "Color 1", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(0, 0, 0, 1)), showsInBody: false),
                         ParamDecl(name: "pos1", label: "Position 2", kind: .value(.float, range: 0...1), defaultValue: .float(0.5), showsInBody: false),
                         ParamDecl(name: "col1", label: "Color 2", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)), showsInBody: false),
                         ParamDecl(name: "pos2", label: "Position 3", kind: .value(.float, range: 0...1), defaultValue: .float(0.75), showsInBody: false),
                         ParamDecl(name: "col2", label: "Color 3", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 0.5, 0, 1)), showsInBody: false),
                         ParamDecl(name: "col3", label: "Color 4", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 0, 1)), showsInBody: false)],
                requires: ["ramp3", "ramp4"],
                body: .variants(param: "stops", [
                    "2": "{out.out} = mix({param.col0}, {param.col1}, saturate({in.fac}));",
                    "3": "{out.out} = mn_ramp3({in.fac}, {param.col0}, {param.pos1}, {param.col1}, {param.col2});",
                    "4": "{out.out} = mn_ramp4({in.fac}, {param.col0}, {param.pos1}, {param.col1}, {param.pos2}, {param.col2}, {param.col3});",
                ])),
        NodeDef(id: "color.hsv2rgb", title: "HSV to RGB", category: .color,
                inputs: [SocketDecl(name: "hsv", label: "HSV", type: .concrete(.float3), default: .value(.float3(.init(0, 1, 1))), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "RGB", type: .concrete(.float3))],
                requires: ["hsv2rgb"],
                body: .template("{out.out} = mn_hsv2rgb({in.hsv});")),
        NodeDef(id: "color.rgb2hsv", title: "RGB to HSV", category: .color,
                inputs: [SocketDecl(name: "rgb", label: "RGB", type: .concrete(.float3), default: .value(.float3(.init(1, 1, 1))), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "HSV", type: .concrete(.float3))],
                requires: ["rgb2hsv"],
                body: .template("{out.out} = mn_rgb2hsv({in.rgb});")),
        NodeDef(id: "color.invert", title: "Invert", category: .color,
                inputs: [SocketDecl(name: "c", label: "Color", type: .concrete(.color), default: .value(.float4(.init(1, 1, 1, 1))), range: 0...1)],
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                body: .template("{out.out} = float4(1.0 - ({in.c}).rgb, ({in.c}).a);")),
        NodeDef(id: "color.mixcolor", title: "Mix Color", category: .color,
                inputs: [SocketDecl(name: "a", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))), range: 0...1),
                         SocketDecl(name: "b", type: .concrete(.color), default: .value(.float4(.init(1, 1, 1, 1))), range: 0...1),
                         SocketDecl(name: "fac", label: "Factor", type: .concrete(.float), default: .value(.float(0.5)), range: 0...1)],
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                params: [ParamDecl(name: "mode", kind: .enumeration(["mix", "add", "multiply", "screen"]), defaultValue: .enumCase("mix"))],
                body: .variants(param: "mode", [
                    "mix": "{out.out} = mix({in.a}, {in.b}, {in.fac});",
                    "add": "{out.out} = float4(({in.a}).rgb + ({in.b}).rgb * {in.fac}, ({in.a}).a);",
                    "multiply": "{out.out} = float4(mix(({in.a}).rgb, ({in.a}).rgb * ({in.b}).rgb, {in.fac}), ({in.a}).a);",
                    "screen": "{out.out} = float4(mix(({in.a}).rgb, 1.0 - (1.0 - ({in.a}).rgb) * (1.0 - ({in.b}).rgb), {in.fac}), ({in.a}).a);",
                ])),
    ]
}
```

`Library/Builtin/UtilityNodes.swift`:

```swift
import Foundation

extension BuiltinNodes {
    static let anyValue: [SocketType] = [.float, .float2, .float3, .float4, .color, .int, .bool]

    static let utility: [NodeDef] = [
        NodeDef(id: "utility.reroute", title: "Reroute", category: .utility,
                inputs: [SocketDecl(name: "in", label: "In", type: .generic("T"), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyValue],
                body: .template("{out.out} = {in.in};"),
                style: .dot),
        NodeDef(id: "utility.compare", title: "Compare", category: .utility,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(0)), range: -10...10),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(0)), range: -10...10)],
                outputs: [SocketDecl(name: "out", label: "Result", type: .concrete(.bool))],
                params: [ParamDecl(name: "op", label: "Operation", kind: .enumeration(["less", "greater", "equal", "notEqual"]), defaultValue: .enumCase("less"))],
                body: .variants(param: "op", [
                    "less": "{out.out} = {in.a} < {in.b};",
                    "greater": "{out.out} = {in.a} > {in.b};",
                    "equal": "{out.out} = abs({in.a} - {in.b}) < 0.0001;",
                    "notEqual": "{out.out} = abs({in.a} - {in.b}) >= 0.0001;",
                ])),
        NodeDef(id: "utility.switch", title: "Switch", category: .utility,
                inputs: [SocketDecl(name: "cond", label: "Condition", type: .concrete(.bool), default: .value(.bool(false))),
                         SocketDecl(name: "a", label: "True", type: .generic("T"), default: .value(.float(1)), range: -10...10),
                         SocketDecl(name: "b", label: "False", type: .generic("T"), default: .value(.float(0)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": [.float, .float2, .float3, .float4, .color]],
                body: .template("{out.out} = {in.cond} ? {in.a} : {in.b};")),
    ]
}
```

`Library/Stdlib/ColorStdlib.swift`:

```swift
extension MSLStdlib {
    static let color: [MSLFunction] = [
        MSLFunction(name: "rampSegment", dependencies: [], source: """
        float4 mn_rampSegment(float t, float p0, float4 c0, float p1, float4 c1) {
            return mix(c0, c1, saturate((t - p0) / max(p1 - p0, 1e-5)));
        }
        """),
        MSLFunction(name: "ramp3", dependencies: ["rampSegment"], source: """
        float4 mn_ramp3(float t, float4 c0, float p1, float4 c1, float4 c2) {
            return t < p1 ? mn_rampSegment(t, 0.0, c0, p1, c1) : mn_rampSegment(t, p1, c1, 1.0, c2);
        }
        """),
        MSLFunction(name: "ramp4", dependencies: ["rampSegment"], source: """
        float4 mn_ramp4(float t, float4 c0, float p1, float4 c1, float p2, float4 c2, float4 c3) {
            if (t < p1) { return mn_rampSegment(t, 0.0, c0, p1, c1); }
            if (t < p2) { return mn_rampSegment(t, p1, c1, p2, c2); }
            return mn_rampSegment(t, p2, c2, 1.0, c3);
        }
        """),
        MSLFunction(name: "hsv2rgb", dependencies: [], source: """
        float3 mn_hsv2rgb(float3 c) {
            float4 K = float4(1.0, 2.0 / 3.0, 1.0 / 3.0, 3.0);
            float3 p = abs(fract(c.xxx + K.xyz) * 6.0 - K.www);
            return c.z * mix(K.xxx, saturate(p - K.xxx), c.y);
        }
        """),
        MSLFunction(name: "rgb2hsv", dependencies: [], source: """
        float3 mn_rgb2hsv(float3 c) {
            float4 K = float4(0.0, -1.0 / 3.0, 2.0 / 3.0, -1.0);
            float4 p = mix(float4(c.bg, K.wz), float4(c.gb, K.xy), step(c.b, c.g));
            float4 q = mix(float4(p.xyw, c.r), float4(c.r, p.yzx), step(p.x, c.r));
            float d = q.x - min(q.w, q.y);
            float e = 1.0e-10;
            return float3(abs(q.z + (q.w - q.y) / (6.0 * d + e)), d / (q.x + e), q.x);
        }
        """),
    ]
}
```

`MSLStdlib.all = core + vector + sdf + noise + color`; `BuiltinNodes.all = input + math + vector + sdf + noise + color + utility + output`. Note the ramp's `requires: ["ramp3", "ramp4"]` pulls both helpers into every ramp program even for 2 stops — acceptable (tiny); `MSLStdlib.resolve` de-duplicates `rampSegment`.

`Emitter.referencedNames` already limits uniform requests to the chosen variant's placeholders, which is what `colorRampOnlyClaimsSlotsForItsChosenStopCount` asserts.

- [ ] **Step 4: Run** the full suite + GPU smoke (`--filter ShaderCompilerTests`): all 40 nodes, every variant (ramp ×3, mix color ×4, compare ×4, math ×15, uv ×2), every viewer type, every stitchable kind.

- [ ] **Step 5: Commit** — `feat(core): library — Color Ramp, HSV/RGB, Invert, Mix Color, Reroute, Compare, Switch (v1 set complete)`

---

### Task 9: Viewer range in the renderer; viewer, error and compile plumbing in `EditorModel`

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift`, `UniformImage.swift`, `ShaderRenderer.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Viewer.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/UniformImageTests.swift`, `MetalNodesKit/Tests/MetalNodesUITests/EditorViewerTests.swift`, `EditorModelTests.swift`

**Interfaces:**
- Produces: `PreviewState.viewerRange: ClosedRange<Float>` (default `0...1`); `UniformImage.setViewerRange(_:)` (no-op without the reserved fields); `EditorModel.viewer`, `setViewer(_:)`, `toggleViewer(_:)`, `toggleViewerOnSelection()`, `firstOutput(of:)`, `viewedType`, `socketLabel(_:)`, `errorNodes`, `pruneViewer()`; `scheduleCompile()` becomes internal; compile skipped when `(source, fastMath)` is unchanged; `compileNow` passes `viewer` and `settings.target`; `.setSettings` recompiles when `target` changes.

- [ ] **Step 1: Write the failing tests**

`UniformImageTests` additions:

```swift
    @Test func viewerRangeWritesOnlyWhenTheLayoutHasIt() {
        var plain = UniformImage(layout: UniformLayoutBuilder.build([]))
        plain.setViewerRange(0.2...0.8)                       // must not trap
        var viewer = UniformImage(layout: UniformLayoutBuilder.build([], reserved: UniformLayoutBuilder.viewerReserved))
        viewer.setViewerRange(0.25...0.75)
        let lo = viewer.layout.reserved("viewerMin").offset, hi = viewer.layout.reserved("viewerMax").offset
        #expect(viewer.bytes[lo..<lo + 4].withUnsafeBytes { $0.load(as: Float.self) } == 0.25)
        #expect(viewer.bytes[hi..<hi + 4].withUnsafeBytes { $0.load(as: Float.self) } == 0.75)
    }
```

`EditorViewerTests.swift`:

```swift
import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

@MainActor
@Suite struct EditorViewerTests {
    private func model() -> (EditorModel, RecordingCompiler) {
        let c = RecordingCompiler()
        let m = EditorModel(document: .sample(), compiler: c)
        m.debounceInterval = .milliseconds(5)
        return (m, c)
    }
    private func node(_ m: EditorModel, _ defID: String) -> NodeInstance { m.document.root.nodes.values.first { $0.kind == .builtin(defID) }! }

    @Test func settingTheViewerSchedulesOneCompileAndIsNotUndoable() async {
        let (m, c) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out"))
        await m.awaitIdle()
        #expect(m.viewer == SocketRef(noise.id, "out"))
        #expect(await c.generations.count == 2)
        #expect(!m.canUndo)
        #expect(m.generatedSource.contains("u.viewerMin"))
        #expect(m.viewedType == .float)
    }

    @Test func toggleClearsWhenAlreadyViewed() async {
        let (m, _) = model()
        let noise = node(m, "noise.value")
        m.toggleViewer(SocketRef(noise.id, "out"))
        m.toggleViewer(SocketRef(noise.id, "out"))
        #expect(m.viewer == nil)
    }

    @Test func toggleOnSelectionUsesTheFirstOutput() {
        let (m, _) = model()
        let sep = node(m, "vector.separate")
        m.select(sep.id)
        m.toggleViewerOnSelection()
        #expect(m.viewer == SocketRef(sep.id, "x"))
        m.select(nodes: [sep.id, node(m, "input.uv").id], mode: .replace)
        m.toggleViewerOnSelection()                    // two selected: no change
        #expect(m.viewer == SocketRef(sep.id, "x"))
    }

    @Test func deletingTheViewedNodeClearsTheViewer() async {
        let (m, c) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out")); await m.awaitIdle()
        m.apply(.removeNodes([noise.id])); await m.awaitIdle()
        #expect(m.viewer == nil)
        #expect(!m.generatedSource.contains("u.viewerMin"))
        #expect(await c.generations.count == 3)
    }

    @Test func undoRestoresTheNodeButNotTheViewer() async {
        let (m, _) = model()
        m.start(); await m.awaitIdle()
        let noise = node(m, "noise.value")
        m.setViewer(SocketRef(noise.id, "out"))
        m.apply(.removeNodes([noise.id]))
        m.undo(); await m.awaitIdle()
        #expect(m.document.root.nodes[noise.id] != nil)
        #expect(m.viewer == nil)                       // view state is never undone (spec §5)
    }

    @Test func socketLabelUsesCustomTitleThenDefinitionTitle() {
        let (m, _) = model()
        let noise = node(m, "noise.value")
        #expect(m.socketLabel(SocketRef(noise.id, "out")) == "Value Noise.out")
        m.apply(.setTitle(noise.id, "Grain"))
        #expect(m.socketLabel(SocketRef(noise.id, "out")) == "Grain.out")
    }

    @Test func errorNodesComeFromErrorDiagnosticsOnly() async {
        let (m, _) = model()
        m.start(); await m.awaitIdle()
        #expect(m.errorNodes.isEmpty)
        let mul = node(m, "math.math")
        m.apply(.connect(from: SocketRef(mul.id, "out"), to: SocketRef(mul.id, "b")))   // a cycle
        await m.awaitIdle()
        #expect(m.errorNodes.contains(mul.id))
    }
}
```

`EditorModelTests` additions (plus, next to `WarningCompiler`, a counting fake):

```swift
/// Fails every time and counts how often it was asked — the outcome that must be *reused* for unchanged source.
actor CountingFailingCompiler: ShaderCompiling {
    private(set) var calls = 0
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        calls += 1
        return .failure(message: "synthetic", lines: [CompileLine(line: 999, message: "nowhere")], generation: generation)
    }
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
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

Render:
- `PreviewState`: `public var viewerRange: ClosedRange<Float> = 0...1`.
- `UniformImage`: `public mutating func setViewerRange(_ r: ClosedRange<Float>) { guard layout.hasReserved("viewerMin") else { return }; write(.float(r.lowerBound), into: layout.reserved("viewerMin")); write(.float(r.upperBound), into: layout.reserved("viewerMax")) }`.
- `ShaderRenderer.draw`: after `image.setReserved(...)`, `image.setViewerRange(state.viewerRange)`.

UI — `EditorModel.swift`:
- `private func scheduleCompile()` → `func scheduleCompile()`.
- Add `private var lastCompiled: (source: String, fastMath: Bool, succeeded: Bool)?` — the last **non-superseded** compile.
- `perform`: in `.setSettings` also `|| s.target != document.settings.target`; after `.removeNodes(...)` and `.restore(...)`, call `_ = pruneViewer()` (the change is topology anyway).
- `compileNow`: `generateResult(doc, target: doc.settings.target, viewer: viewState.viewer, registry: registry)`; **before** the existing `diagnostics = []` line:
  ```swift
        if let last = lastCompiled, last.source == shader.source, last.fastMath == doc.settings.fastMath {
            // Same program as the last settled compile (typically an undo of a cosmetic edit): its
            // outcome still stands. Refresh what depends on the document and skip the compiler (§19.1).
            generatedSource = shader.source
            resolvedTypes = shader.resolved
            if last.succeeded, let p = preview.pipeline {
                diagnostics = []
                preview.uniforms = UniformImage.rebuild(layout: p.shader.layout, document: document, registry: registry)
            }
            return
        }
  ```
  In the `.success` branch set `lastCompiled = (shader.source, doc.settings.fastMath, true)`; in `.failure` set `lastCompiled = (shader.source, doc.settings.fastMath, false)`; `.superseded` leaves it alone. A generation-guard early return (`guard pipeline.generation == generation`) happens before either assignment.
- `generateResult` takes `target` and `viewer`.
- `public var errorNodes: Set<NodeID> { Set(diagnostics.filter { $0.severity == .error }.compactMap(\.node)) }`.
- `public func socketLabel(_ ref: SocketRef) -> String` (moved from `InspectorView.sourceLabel`; the inspector calls it).

`Editor/EditorModel+Viewer.swift`:

```swift
import MetalNodesCore

/// The ◉ flag (spec §9.3, §19.3). View state, never undone; changing it recompiles.
extension EditorModel {
    public var viewer: SocketRef? { viewState.viewer }

    public func setViewer(_ ref: SocketRef?) {
        guard viewState.viewer != ref else { return }
        viewState.viewer = ref
        scheduleCompile()
    }

    public func toggleViewer(_ ref: SocketRef) { setViewer(viewState.viewer == ref ? nil : ref) }

    /// The node's first declared output, the socket the header badge and ⌘⇧V act on.
    public func firstOutput(of id: NodeID) -> SocketRef? {
        guard let n = document.root.nodes[id], case .builtin(let defID) = n.kind,
              let first = registry[defID]?.outputs.first else { return nil }
        return SocketRef(id, first.name)
    }

    public func toggleViewerOnSelection() {
        guard selection.count == 1, let id = selection.first, let ref = firstOutput(of: id) else { return }
        toggleViewer(ref)
    }

    public var viewedType: SocketType? {
        guard let v = viewer else { return nil }
        return resolvedTypes[v.node]?.outputTypes[v.socket]
    }

    /// Clears a viewer whose socket no longer exists. Returns true if it did.
    @discardableResult
    func pruneViewer() -> Bool {
        guard let v = viewState.viewer, !GraphValidator.isValidViewer(v, in: document.root, registry: registry) else { return false }
        viewState.viewer = nil
        return true
    }
}
```

- [ ] **Step 4: Run** `swift test --package-path MetalNodesKit` — green.

- [ ] **Step 5: Commit** — `feat(ui,render): viewer state and range, error nodes, target recompile, unchanged-source compile skip`

---

### Task 10: Viewer UI — header badge, preview strip, inspector output rows, ⌘⇧V

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift`, `Canvas/GraphCanvasView.swift`, `Editor/EditorView.swift`, `Editor/InspectorView.swift`, `Editor/EditorCommands.swift`

**Interfaces:**
- Consumes: T9. `NodeView` gains `isViewed: Bool`, `hasError: Bool` (used in T11), `onViewerToggle: () -> Void`.

- [ ] **Step 1: `NodeView` header badge**

Add the three properties after `compact` (`var isViewed = false`, `var hasError = false`, `var onViewerToggle: () -> Void = {}`). In `header`, before the compact outputs (`if compact { … outputs … }`), insert:

```swift
            Image(systemName: isViewed ? "circle.circle.fill" : "circle.circle")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isViewed ? DraculaTheme.viewerFlag.color : DraculaToken.background.color.opacity(0.55))
                .padding(3)
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { onViewerToggle() })
                .accessibilityLabel(isViewed ? "Clear viewer" : "View this node")
```

(`highPriorityGesture` on the badge beats the header's `DragGesture(minimumDistance: 0)`; hit-testing stops at the badge's own padded frame, so keep the padding — do not rely on an inset content shape.)

- [ ] **Step 2: Canvas plumbing** — in the `ForEach(visible)` `NodeView(...)` call add `isViewed: model.viewer?.node == node.id, hasError: errors.contains(node.id), onViewerToggle: { if let ref = model.firstOutput(of: node.id) { model.toggleViewer(ref) } }` where `let errors = model.errorNodes` is computed once above the `ForEach`.

- [ ] **Step 3: Preview strip** — in `EditorView.previewPane`, after the Pause/Reset `HStack`:

```swift
            if let v = model.viewer {
                HStack(spacing: 6) {
                    Image(systemName: "circle.circle.fill").foregroundStyle(DraculaTheme.viewerFlag.color)
                    Text("Viewing \(model.socketLabel(v))").font(.caption).lineLimit(1)
                    if model.viewedType == .float || model.viewedType == .int {
                        TextField("Min", value: rangeBinding(lower: true), format: .number.precision(.fractionLength(2))).frame(width: 56)
                        TextField("Max", value: rangeBinding(lower: false), format: .number.precision(.fractionLength(2))).frame(width: 56)
                    }
                    Spacer()
                    Button("Clear") { model.setViewer(nil) }
                }
                .controlSize(.small)
                .textFieldStyle(.roundedBorder)
            }
```

with

```swift
    private func rangeBinding(lower: Bool) -> Binding<Float> {
        Binding(
            get: { lower ? model.preview.viewerRange.lowerBound : model.preview.viewerRange.upperBound },
            set: { x in
                let r = model.preview.viewerRange
                let lo = lower ? x : r.lowerBound, hi = lower ? r.upperBound : x
                model.preview.viewerRange = lo...max(hi, lo + 0.0001)
            })
    }
```

- [ ] **Step 4: Inspector output rows** — in `nodePane`, after the params `ForEach`, add:

```swift
            if !def.outputs.isEmpty {
                Divider()
                ForEach(def.outputs, id: \.name) { decl in
                    let ref = SocketRef(id, decl.name)
                    let viewed = model.viewer == ref
                    HStack {
                        Text(decl.label).font(.caption)
                        Text((resolved?.outputTypes[decl.name] ?? decl.type.concreteOrFloat).rawValue)
                            .font(.caption2.monospaced()).foregroundStyle(DraculaToken.muted.color)
                        Spacer()
                        Button { model.toggleViewer(ref) } label: {
                            Image(systemName: viewed ? "circle.circle.fill" : "circle.circle")
                                .foregroundStyle(viewed ? DraculaTheme.viewerFlag.color : DraculaToken.muted.color)
                        }
                        .buttonStyle(.plain)
                        .help(viewed ? "Clear viewer" : "View \(decl.label)")
                    }
                }
            }
```

Replace `sourceLabel(src)` with `model.socketLabel(src)` and delete the private helper.

- [ ] **Step 5: Command** — in `EditorCommands`, inside the `CommandGroup(after: .sidebar)` block, after the zoom items:

```swift
            Divider()
            Button("Toggle Viewer") { model?.toggleViewerOnSelection() }
                .keyboardShortcut("v", modifiers: [.command, .shift])
                .disabled(!(model?.canvasHasFocus ?? false) || (model?.selection.count ?? 0) != 1)
```

- [ ] **Step 6: Build and run** — `swift build --package-path MetalNodesKit` warning-free; `swift test --package-path MetalNodesKit` green; `xcodebuild … build` succeeds; launch the app: click a ◉ on Value Noise → preview shows grayscale noise, strip reads "Viewing Value Noise.out" with Min/Max; click again → back to the full shader. Then `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 7: Commit** — `feat(ui): viewer flag — header badge, preview strip with range, inspector output rows, ⌘⇧V`

---

### Task 11: Error outline, Reroute dot, hidden params, and the M2 carry-overs

**Files:**
- Modify: `Canvas/NodeView.swift`, `Canvas/NodeGeometry.swift`, `Canvas/GraphCanvasView.swift`, `Editor/EditorModel+Selection.swift`, `Editor/EditorCommands.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Clipboard/GraphClipboard.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift`, `MetalNodesKit/Tests/MetalNodesCoreTests/GraphClipboardTests.swift`

**Interfaces:**
- Produces: `NodeGeometry.estimatedSize` honours `.dot` (24 × 24) and `showsInBody`; `NodeGeometry.socketAnchor` for dots; `NodeGeometry.visibleNodes(..., onTop: Set<NodeID>)` draws `onTop` last; `EditorModel.node(at:)` matches that order; `GraphClipboard` decodes missing keys; paste lands at the pointer.

- [ ] **Step 1: Write the failing tests**

`NodeGeometryTests`:

```swift
    @Test func dotNodesAreSmallAndAnchorOnTheirEdges() throws {
        let reg = NodeRegistry.builtin
        let r = NodeInstance(kind: .builtin("utility.reroute"), position: CGPoint(x: 100, y: 50))
        var g = Graph(); g.nodes[r.id] = r
        #expect(NodeGeometry.frame(for: r, registry: reg) == CGRect(x: 100, y: 50, width: 24, height: 24))
        #expect(NodeGeometry.socketAnchor(for: SocketRef(r.id, "in"), in: g, registry: reg) == CGPoint(x: 100, y: 62))
        #expect(NodeGeometry.socketAnchor(for: SocketRef(r.id, "out"), in: g, registry: reg) == CGPoint(x: 124, y: 62))
    }

    @Test func hiddenParamsDoNotCountAsBodyRows() throws {
        let ramp = try #require(NodeRegistry.builtin["color.ramp"])
        // header 26 + padding 16 + rows (1 input + 1 visible param + 1 output) × 22
        #expect(NodeGeometry.estimatedSize(for: ramp).height == 108)
    }

    @Test func nodesOnTopDrawLast() {
        let doc = ShaderDocument.sample()
        let uv = doc.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
        let vis = NodeGeometry.visibleNodes(in: doc.root, transform: CanvasTransform(pan: .zero, zoom: 0.15),
                                            viewport: CGSize(width: 4000, height: 4000), registry: .builtin, margin: 200, onTop: [uv.id])
        #expect(vis.last?.id == uv.id)
        #expect(vis.count == doc.root.nodes.count)
    }
```

`GraphClipboardTests`:

```swift
    @Test func decodingToleratesMissingOptionalKeys() throws {
        let json = #"{"nodes":[],"edges":[]}"#
        let clip = try JSONDecoder().decode(GraphClipboard.self, from: Data(json.utf8))
        #expect(clip.formatVersion == 1)
        #expect(clip.sourceOrigin == .zero)
        #expect(clip.stickies.isEmpty && clip.frames.isEmpty && clip.definitions.isEmpty)
    }
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`NodeGeometry`:
```swift
    static let dotSize: CGFloat = 24

    static func bodyRows(_ def: NodeDef) -> Int {
        def.inputs.count + def.params.filter(\.showsInBody).count + def.outputs.count
    }

    static func estimatedSize(for def: NodeDef) -> CGSize {
        if def.style == .dot { return CGSize(width: dotSize, height: dotSize) }
        return CGSize(width: width, height: headerHeight + bodyPadding + CGFloat(bodyRows(def)) * rowHeight)
    }
```
`socketAnchor`: `if def.style == .dot { return def.input(named: ref.socket) != nil ? CGPoint(x: node.position.x, y: node.position.y + dotSize / 2) : def.output(named: ref.socket) != nil ? CGPoint(x: node.position.x + dotSize, y: node.position.y + dotSize / 2) : nil }`; the output row index uses `def.inputs.count + def.params.filter(\.showsInBody).count + i`. `visibleNodes` gains `onTop: Set<NodeID> = []` and sorts by `(onTop.contains(id) ? 1 : 0, uuidString)`.

`GraphCanvasView`: pass `onTop: model.selection` to `visibleNodes`; the `viewport == .zero` branch sorts the same way. `EditorModel.node(at:)` sorts by `(selection.contains(id) ? 1 : 0, uuid)` and takes `.last`. Paste: `.onPasteCommand(of: [.metalNodesGraph]) { _ in model.paste(at: transform.toCanvas(hoverLocation)) }` — `hoverLocation` is the last pointer position inside the viewport, reset to the centre when the pointer leaves (T11 of M2), so a menu paste lands at the centre.

`NodeView`:
- Outline: `.overlay(RoundedRectangle(cornerRadius: 8).stroke(hasError ? DraculaTheme.error.color : (isSelected ? DraculaTheme.selection.color : DraculaToken.background.color), lineWidth: hasError || isSelected ? 2 : 1))`.
- Header leading badge, before the title: `if hasError { Image(systemName: "exclamationmark.circle.fill").font(.system(size: 10)).foregroundStyle(DraculaTheme.error.color) }`.
- Body params: `ForEach(def.params.filter(\.showsInBody), id: \.name)`.
- Dot style: `body` becomes `Group { if def.style == .dot { dotBody } else { standardBody } }` where `standardBody` is the existing VStack chain and:

```swift
    private var dotBody: some View {
        let type = resolved?.outputTypes[def.outputs.first?.name ?? ""] ?? .float
        return ZStack {
            Circle().fill(DraculaToken.surface.color)
            Circle().fill(DraculaTheme.token(for: type).color).padding(6)
            Circle().stroke(hasError ? DraculaTheme.error.color : (isSelected ? DraculaTheme.selection.color : DraculaToken.background.color),
                            lineWidth: hasError || isSelected ? 2 : 1)
            if let i = def.inputs.first {
                SocketView(type: resolved?.inputTypes[i.name] ?? .float, dimmed: dragType.map { !DropResolver.compatible($0, resolved?.inputTypes[i.name] ?? .float) } ?? false)
                    .opacity(0.001).socketAnchor(SocketRef(node.id, i.name))
                    .gesture(socketDrag(SocketRef(node.id, i.name), isInput: true))
                    .frame(maxWidth: .infinity, alignment: .leading).offset(x: -SocketView.size / 2)
            }
            if let o = def.outputs.first {
                SocketView(type: type, dimmed: dragType != nil)
                    .opacity(0.001).socketAnchor(SocketRef(node.id, o.name))
                    .gesture(socketDrag(SocketRef(node.id, o.name), isInput: false))
                    .frame(maxWidth: .infinity, alignment: .trailing).offset(x: SocketView.size / 2)
            }
        }
        .frame(width: NodeGeometry.dotSize, height: NodeGeometry.dotSize)
        .shadow(color: isSelected ? DraculaTheme.selection.color.opacity(0.35) : .black.opacity(0.35), radius: isSelected ? 8 : 4, y: isSelected ? 0 : 2)
        .contentShape(Circle())
        .gesture(headerDrag)          // the existing header DragGesture, extracted into a computed property
    }
```

The invisible `SocketView`s keep the anchors and the socket drags working exactly as on a standard node; the dot's own colour shows the resolved type. Extract the header's `DragGesture` into `private var headerDrag: some Gesture` so both bodies share it.

`EditorCommands` undo titles: `Button(model?.undoManager.undoMenuItemTitle ?? "Undo")` / `Button(model?.undoManager.redoMenuItemTitle ?? "Redo")` (these read `undoActionName`; `commitUndo` already calls `setActionName`).

`GraphClipboard` tolerant decoding:

```swift
extension GraphClipboard {
    private enum Keys: String, CodingKey { case formatVersion, sourceOrigin, nodes, edges, stickies, frames, definitions }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? GraphClipboard.currentFormatVersion
        sourceOrigin = try c.decodeIfPresent(CGPoint.self, forKey: .sourceOrigin) ?? .zero
        nodes = try c.decodeIfPresent([NodeInstance].self, forKey: .nodes) ?? []
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? []
        stickies = try c.decodeIfPresent([StickyNote].self, forKey: .stickies) ?? []
        frames = try c.decodeIfPresent([CommentFrame].self, forKey: .frames) ?? []
        definitions = try c.decodeIfPresent([GroupDefinition].self, forKey: .definitions) ?? []
    }
}
```
(keep the synthesized `encode`; remove `Codable` from the struct declaration's conformance list in favour of `Encodable` + this `Decodable`, or keep `Codable` and only supply `init(from:)` — the latter compiles).

- [ ] **Step 4: Run** the full suite, build the app, verify by hand: a Reroute from ⇧A shows as a dot and wires through it; a Color Ramp shows only the Stops picker in its body and all seven controls in the inspector; a cycle (connect Math.out → Math.b) outlines Math in red; ⌘V pastes under the pointer; Edit ▸ Undo reads "Undo Move" after a drag.

- [ ] **Step 5: Commit** — `feat(ui): error outlines, Reroute dot, hidden params, paste at pointer, selected-on-top, undo titles, tolerant clipboard`

---

### Task 12: Mouse tracking in the preview

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift`

**Interfaces:**
- Produces: `PreviewState.mouse` follows the pointer over the preview: normalised, bottom-left origin; the last position sticks when the pointer leaves.

- [ ] **Step 1: Implement** — wrap `PreviewView` in a `GeometryReader` overlay:

```swift
            PreviewView(state: model.preview, device: device)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        Color.clear
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let p) = phase { setMouse(p, in: geo.size) }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { g in setMouse(g.location, in: geo.size) })
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
```

```swift
    private func setMouse(_ p: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        model.preview.mouse = SIMD2(Float(min(max(p.x / size.width, 0), 1)), Float(1 - min(max(p.y / size.height, 0), 1)))
    }
```

- [ ] **Step 2: Verify by hand** — add a Mouse node wired to Fragment Output (float2 → color: red = x, green = y); moving the pointer over the preview changes the colour; bottom-left is black.

- [ ] **Step 3: Commit** — `feat(ui): preview pointer drives the Mouse node`

---

### Task 13: Output target, export name, Copy Swift snippet, File ▸ Export Shader…

**Files:**
- Modify: `Editor/InspectorView.swift`, `Editor/EditorModel.swift`, `Editor/EditorCommands.swift`, `Editor/EditorView.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/ExportPanelMac.swift`
- Modify: `MetalNodes.xcodeproj/project.pbxproj` (build setting only)
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift`

**Interfaces:**
- Produces: `EditorModel.exportFiles() throws(GenerationError) -> [ExportFile]`, `copySwiftSnippet() -> Bool`, `requestExport()`, `exportRequest: Int`; `ExportPanelMac.run(files:)` (macOS).

- [ ] **Step 1: Write the failing tests**

```swift
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
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`EditorModel`:

```swift
    /// Bumped by File ▸ Export Shader…; the macOS view presents the save panel on change.
    public private(set) var exportRequest = 0
    public func requestExport() { exportRequest += 1 }

    public func exportFiles() throws(GenerationError) -> [ExportFile] {
        try ShaderExport.files(for: document, registry: registry)
    }

    /// Puts the `.swift` snippet on the pasteboard as plain text. False for the fragment target.
    @discardableResult
    public func copySwiftSnippet() -> Bool {
        guard let files = try? exportFiles(), let swift = files.first(where: { $0.name.hasSuffix(".swift") }) else { return false }
        pasteboard.write(Data(swift.contents.utf8), type: "public.utf8-plain-text")
        return true
    }
```

`InspectorView.documentSettings` — after the Fast math toggle:

```swift
            Divider()
            Text("Output").font(.headline)
            Picker("Target", selection: Binding(get: { s.target }, set: { t in var n = s; n.target = t; model.apply(.setSettings(n)) })) {
                ForEach(OutputTarget.all, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            HStack {
                Text("Export name").font(.caption)
                TextField("metalNodesShader", text: $exportNameDraft)
                    .onAppear { exportNameDraft = s.exportName }
                    .onChange(of: model.document.settings.exportName) { _, n in exportNameDraft = n }
                    .onSubmit { var n = s; n.exportName = StitchableCodegen.sanitizedName(exportNameDraft); exportNameDraft = n.exportName; model.apply(.setSettings(n)) }
            }
            HStack {
                Button("Copy Swift snippet") { _ = model.copySwiftSnippet() }
                    .disabled(s.target.stitchableKind == nil)
                #if os(macOS)
                Button("Export…") { model.requestExport() }
                #endif
            }
            .controlSize(.small)
            if s.target.stitchableKind != nil {
                Text("Preview renders the same function through a fragment wrapper. Export writes the .metal file and a .swift extension with the ShaderLibrary call in argument order.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
```

(`@State private var exportNameDraft = ""`.)

`Editor/ExportPanelMac.swift`:

```swift
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
import MetalNodesCore

/// File ▸ Export Shader…: one save panel for the `.metal`; the `.swift` (if any) is written beside it
/// under the same base name.
enum ExportPanelMac {
    /// Returns an error message to show, or nil on success/cancel.
    static func run(files: [ExportFile]) -> String? {
        guard let metal = files.first(where: { $0.name.hasSuffix(".metal") }) else { return "Nothing to export." }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = metal.name
        panel.allowedContentTypes = [UTType(filenameExtension: "metal") ?? .sourceCode]
        panel.canCreateDirectories = true
        panel.title = "Export Shader"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let base = url.deletingPathExtension()
        do {
            try metal.contents.write(to: url, atomically: true, encoding: .utf8)
            if let swift = files.first(where: { $0.name.hasSuffix(".swift") }) {
                try swift.contents.write(to: base.appendingPathExtension("swift"), atomically: true, encoding: .utf8)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
#endif
```

`EditorView`: `@State private var exportError: String?`; on `body`:

```swift
            .onChange(of: model.exportRequest) { _, _ in
                #if os(macOS)
                do { exportError = ExportPanelMac.run(files: try model.exportFiles()) }
                catch { exportError = "The graph has errors; fix them before exporting." }
                #endif
            }
            .alert("Export failed", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
                Button("OK") { exportError = nil }
            } message: { Text(exportError ?? "") }
```

`EditorCommands`:

```swift
        CommandGroup(after: .saveItem) {
            Button("Export Shader…") { model?.requestExport() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model == nil)
        }
```

`project.pbxproj`: in **both** app-target build configurations (the blocks that contain `ENABLE_APP_SANDBOX = YES;`), add the line `ENABLE_USER_SELECTED_FILES = readwrite;` directly after it. Commit only that hunk — inspect `git diff MetalNodes.xcodeproj/project.pbxproj` and revert anything else in the file.

- [ ] **Step 4: Run** the suite, build the app, verify by hand: switch Target to "SwiftUI Color Effect" → preview keeps rendering (gen +1) and the diagnostics stay "No problems"; ⌘E → save panel → both files appear next to each other; `xcrun -sdk macosx metal -c <file>.metal -o /dev/null` succeeds (if the toolchain is installed); "Copy Swift snippet" → paste in a text editor shows the extension.

- [ ] **Step 5: Commit** — `feat(ui,app): output target and export name in the inspector, Copy Swift snippet, File ▸ Export Shader… (⌘E) with user-selected file access`

---

### Task 14: Integration — build, suite, greps, manual checklist

**Files:**
- Modify (only if a check fails): whichever file the failure points at, with the fix committed as `fix(…): <what> — manual check N`.

- [ ] **Step 1: Clean build and full suite**

```bash
swift build --package-path MetalNodesKit 2>&1 | grep -iE 'warning|error' ; echo build-grep-done
swift test --package-path MetalNodesKit 2>&1 | grep -E 'Test run with|failed'
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD'
git checkout -- MetalNodes.xcodeproj/project.pbxproj   # only if the diff is key reorders; the T13 setting is already committed
rm -rf MetalNodes.xcodeproj/xcshareddata
```
Expected: no warnings; three suite lines all "passed" (≈ Core 115 / Render 24 / UI 90); `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Done-criteria greps**

```bash
grep -rn '0x[0-9A-Fa-f]\{6\}' MetalNodesKit/Sources --include='*.swift' | grep -v DraculaTheme          # empty
grep -rn '^import' MetalNodesKit/Sources/MetalNodesCore | grep -vE 'Foundation|CoreGraphics'              # empty
grep -rn 'u\.time\|u\.resolution\|u\.mouse\|in\.uv' MetalNodesKit/Sources/MetalNodesCore/Library           # empty: templates use {sys.*}
grep -rln 'import AppKit' MetalNodesKit/Sources --include='*.swift' | xargs grep -L '#if os(macOS)\|#if canImport(AppKit)'   # empty
```

- [ ] **Step 3: Manual checklist** (launch the built app; record each as observed/failed)

1. **Palette** — eight categories in order Input / Math / Vector / SDF / Noise / Color / Utility / Output; 39 rows (40 minus nothing — Fragment Output is listed too); search "noi" lists the four noise nodes.
2. **Viewer flick** — ◉ on Value Noise: preview turns to grayscale noise, gen +1, strip shows "Viewing Value Noise.out" with Min/Max; ◉ on Combine XYZ: colour field, gen +1; ◉ back on Value Noise: gen +1 but instantaneous (cache); Clear: full shader, gen +1.
3. **Range** — with Value Noise viewed, Max = 0.5 → brighter; Min = 0.5, Max = 1 → darker; no gen change while editing.
4. **Inspector ◉** — select Separate XYZ: three output rows with ◉; click the `y` row's ◉ → preview shows a vertical gradient; the header badge is filled; ⌘⇧V on the selected node toggles the viewer off (first output rule: pressing again views `x`).
5. **Delete the viewed node** — ⌫ → viewer cleared, strip gone, preview shows the shader without it (or an error, which is fine); ⌘Z brings the node back but not the viewer.
6. **Error mapping** — connect Math(Multiply).out → its own `b`: red outline + badge on that Math node, message in the inspector; disconnect → outline gone.
7. **Stitchable preview** — Output target = Color Effect: preview identical to Fragment, gen +1; Distortion Effect: preview shows the uv field (UV → Output looks like a red/green gradient); Layer Effect: renders like Color Effect.
8. **Export** — ⌘E with Color Effect → save panel → two files; `xcrun -sdk macosx metal -c <name>.metal -o /dev/null` succeeds; the `.swift` lists `size, time, mouse` then one parameter per unwired slot with node·label comments.
9. **Copy Swift snippet** — button disabled under Fragment, enabled under a stitchable target; pasted text starts with `// <name>.swift`.
10. **Export name** — type "My Shader" → sanitised to `My_Shader` on submit; preview keeps rendering (topology change: gen +1).
11. **New nodes render** — ⇧A each of: Perlin, Simplex, Voronoi, Fbm (octaves stepper 1…8), Circle, Box, Color Ramp (Stops 2/3/4, edit Color 2 in the inspector), HSV to RGB, Mix Color (mode Screen), Compare → Switch chain, Rotate 2D on UV; each wired to Fragment Output renders without "problems".
12. **Reroute** — ⇧A "Reroute": a dot; wire Color → dot → Mix.b; the dot is yellow (color); drag it; select it (outline ring); ⌫ removes it and its wires.
13. **Hidden params** — Color Ramp body shows only Stops; inspector shows Stops + four colours + two positions; ramp height on canvas matches (no empty rows).
14. **Mouse** — Mouse → Fragment Output; pointer over the preview changes the colour; bottom-left is black, top-right yellow.
15. **Paste at pointer** — copy a node, move the pointer to an empty area, ⌘V: the node appears under the pointer; Edit ▸ Paste with the pointer on the menu bar: appears at the viewport centre.
16. **Selected on top** — drag a node over another: while selected it draws above; click the other: it comes to the front.
17. **Undo titles** — after a drag, Edit menu reads "Undo Move"; after a slider, "Undo Change Value".
18. **Unchanged source** — move a node, ⌘Z: gen unchanged (no recompile); toggle Fast math: gen +1.

- [ ] **Step 4: Commit any fixes**, then re-run Step 1.

---

## Done criteria for this plan

- 40 builtin node definitions; every one compiles on the device as a one-node graph, every variant of every variants node, every viewer type, every stitchable kind's preview; an exported `.metal` compiles with the Metal toolchain when present.
- Viewer flag works from the header, the inspector and ⌘⇧V; range control never recompiles; viewer is never undone and is pruned with its node.
- `settings.target` selects fragment / colorEffect / distortionEffect / layerEffect; export writes `NAME.metal` (+ `NAME.swift` with the `ShaderLibrary` call in argument order); "Copy Swift snippet" works.
- Error diagnostics outline their node; warnings do not.
- All greps in Task 14 Step 2 empty; suite green; warning-free; all 18 manual checks observed.

## What the next plan (M4: groups) starts from

`GroupDefinition`/`GraphPath`/`editingStack` exist; `EmitEnvironment` is where a group function's `constant Uniforms &u` parameter and per-instance slot naming (`ParamPath.instancePath`) plug in; `PaletteView`'s "My Functions" section is the hook; `NodeStyle` can grow a `.group` header style; `NodeKind.group/groupInput/groupOutput` are refused by `GraphValidator` today — that guard is the first thing M4 removes. Deferred from M3: Texture Sample and `layerEffect`'s `layer.sample` (M5 with assets), `UTExportedTypeDeclarations` for the two pasteboard UTIs (needs an Info.plist), ⌘Z inside a focused text field, a numeric readout for int viewers.
