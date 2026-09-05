# MetalNodes M4 — Groups — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reusable functions as node groups (Blender/Houdini style): group a selection (⌘G), dive in and edit the definition, make unique, ungroup, expose/rename/remove sockets, definitions in the palette under "My Functions", definitions travelling with copy/paste, one MSL function per definition in every target, and the viewer working inside a definition.

**Architecture:** A single `NodeShape` describes any node (builtin, group instance, `GroupInput`, `GroupOutput`) to every layout/wiring/typing/drawing consumer, replacing direct `NodeDef` use. The editor binds to an *active graph path* derived from view state; every `DocumentChange` applies to that graph. Codegen emits one target-agnostic MSL function per reachable definition (system values, exposed inputs and every uniform it needs as parameters) and calls it at each instance; uniform slots follow spec §9.2 with `ParamPath` depth 1. The five group operations are pure `ShaderDocument` transforms behind new `DocumentChange` cases, so snapshot undo covers definition + instances + orphaned wires in one step. The viewer inside a definition is a "view variant" of each definition on the editing stack.

**Tech Stack:** Swift 6.4, SwiftUI (macOS 26 / iPadOS 27), Metal, Swift Testing, SwiftPM local package `MetalNodesKit`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §3 (document model), §4 (the five operations), §6 (copy/paste), §9.2 (parameter scoping), §9.3 (viewer in a definition), §12 (group header), §14 (tests) and **§20 (M4 addendum)**, which pins the mechanics. Read §20 in full before any task.

## Global Constraints

- Swift language mode `6`, strict concurrency, warning-free build (`swift build --package-path MetalNodesKit 2>&1 | grep -i warning` prints nothing).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics` (no CryptoKit — the content hash is FNV-1a over canonical JSON). `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore`. `MetalNodesUI` may import AppKit only under `#if os(macOS)` in `*Mac.swift` files or clearly gated sections; the `#else` keeps the iPad build plausible.
- `MetalNodesUI` and `MetalNodesUITests` have `.defaultIsolation(MainActor.self)`; Core and Render do not.
- Colors only through `DraculaTheme` / `DraculaToken`; no hex outside `DraculaTheme.swift`. Red = errors only. Group headers use the definition's `DraculaAccent` (default `.purple`) with a doubled border (spec §12, §20.2).
- Every document edit goes through `EditorModel.apply(_:)` on the **active graph path**; views never mutate `document`. Undo = whole-document snapshots in transactions; view state (`EditorViewState`, incl. `editingStack`, `editingDefinition`, `viewer`) is never snapshotted or undone.
- Node ids are unique document-wide; `ShaderDocument.node(_:)` is the lookup. Pseudo-nodes (`GroupInput`/`GroupOutput`) exist exactly once per definition, cannot be deleted, copied, cut or grouped.
- Socket names are C identifiers (`StitchableCodegen.sanitizedName` rules); `SocketRef`s are by name, so a rename rewrites every reference in the same transaction (spec §20.6).
- Uniform slots: per-instance only for unwired exposed inputs of instances in the **root** graph (`ParamPath(node: instanceID, param:)`); everything inside a definition is shared (`ParamPath(node: innerNodeID, param:)`); `instancePath` stays length 1 (spec §20.4).
- Group functions are target-agnostic: `(<sys ×4>, <in_…>, <uniform params>)`, always return a struct, are called with `env.uniform(field)` at the call site (spec §20.4).
- Node width stays `190`; `.dot` 24 × 24. Culling/LOD unchanged.
- Tests: Swift Testing only; goldens compared whole; under `#expect` compare against single typed literals. Package suite: `swift test --package-path MetalNodesKit`. App build: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- Never commit `MetalNodes.xcodeproj/project.pbxproj` key reorders (`git checkout -- MetalNodes.xcodeproj/project.pbxproj` before committing) or `MetalNodes.xcodeproj/xcshareddata/`.

---

## File structure

**Core (`MetalNodesKit/Sources/MetalNodesCore`)**
- Create `NodeShape.swift` — `NodeShape`, `ShaderDocument.shape(of:in:registry:)`, `shape(of id:)` (T1).
- Modify `NodeDef.swift` — `NodeCategory.group` (T1). Modify `ShaderDocument.swift` — `graph(at:)`, `subscript(path)`, `node(_:)`, `GroupDefinition.make`, `inputNode`/`outputNode`, `contentHash` (T1). Modify `EditorViewState.swift` — `editingDefinition`, tolerant `Codable`, `activePath(in:)` (T1).
- Create `Groups/GroupDependencies.swift` — direct/transitive deps, recursion check, inner-first order, reachable set (T1).
- Create `Groups/ContentHash.swift` — FNV-1a over canonical JSON (T1).
- Modify `Codegen/Validation.swift` — document-wide validation via shapes (T2). Modify `Codegen/TypeResolver.swift` — shapes (T2).
- Create `Codegen/GroupCodegen.swift` — `GroupFunction`, function emission, view variants (T3, T4). Modify `Codegen/Emitter.swift` — shapes, `.group`/`.groupInput`/`.groupOutput`, propagation, `functions:` (T3). Modify `Codegen/EmitEnvironment.swift` — `.groupFunction` (T3). Modify `Codegen/ShaderGenerator.swift` — reachable definitions, function block, `viewerPath`/`viewerDefinition` (T3, T4). Modify `Library/SampleDocuments.swift` — `sampleWithGroup()` (T3).
- Create `Groups/GroupOperations.swift` — group/ungroup/makeUnique/rename/sockets/delete/uniqueName (T5).
- Modify `Clipboard/GraphClipboard.swift` — definitions in `extract`, `ClipboardMerge` (T6).

**Render** — Modify `UniformImage.swift` — `rebuild` via `document.node(_:)` + shapes (T3).

**UI (`MetalNodesKit/Sources/MetalNodesUI`)**
- Modify `Editor/EditorModel.swift`, `+Selection`, `+Clipboard`, `+Placement`, `+Viewer`, `DocumentChange.swift`; create `Editor/EditorModel+Groups.swift` (T7).
- Modify `Canvas/NodeGeometry.swift`, `Canvas/DropResolver.swift`, `Canvas/NodeView.swift`, `Canvas/GraphCanvasView.swift`, `Canvas/WireLayer.swift` (T8, T10).
- Create `Editor/BreadcrumbBar.swift`; modify `Editor/EditorView.swift`, `Editor/EditorCommands.swift`, `Editor/InspectorView.swift`; create `Editor/InspectorView+Groups.swift`; modify `Palette/PaletteView.swift`, `Palette/PaletteSearch.swift`, `Palette/NodeDefTransfer.swift` (T9).
- Modify `Theme/DraculaTheme.swift` — `.group` category token (T8).

**Tests** — Core: `NodeShapeTests`, `GroupDependenciesTests`, `GroupValidationTests`, `GroupCodegenTests`, `GroupViewerTests`, `GroupOperationsTests`, `ClipboardMergeTests`; Render: additions to `ShaderCompilerTests`, `UniformImageTests`; UI: `EditorGroupsTests`, additions to `NodeGeometryTests`, `DropResolverTests`, `EditorClipboardTests`, `EditorViewerTests`, `PaletteSearchTests`.

---

### Task 1: Shapes, graph paths, definitions, dependencies

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/NodeShape.swift`, `Groups/GroupDependencies.swift`, `Groups/ContentHash.swift`
- Modify: `NodeDef.swift`, `ShaderDocument.swift`, `EditorViewState.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/NodeShapeTests.swift`, `GroupDependenciesTests.swift`

**Interfaces:**
- Produces: `NodeCategory.group`; `NodeShape` (+ `init(def:)`, `input(named:)`, `output(named:)`, `param(named:)`, `isPseudo`); `ShaderDocument.graph(at:) -> Graph?`, `subscript(path: GraphPath) -> Graph { get set }`, `node(_:) -> (node: NodeInstance, path: GraphPath)?`, `shape(of:in:registry:) -> NodeShape?`, `shape(of id: NodeID, registry:) -> NodeShape?`; `GroupDefinition.make(name:accent:)`, `inputNode`, `outputNode`, `contentHash`; `EditorViewState.editingDefinition: GroupID?`, `activePath(in:) -> GraphPath`; `GroupDependencies.direct(_:)`, `transitive(_:in:)`, `wouldRecurse(placing:in:document:)`, `innerFirst(_:in:)`, `reachable(from:in:)`; `ContentHash.fnv1a(_ data: Data) -> String`.

- [ ] **Step 1: Write the failing tests**

`NodeShapeTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct NodeShapeTests {
    let reg = NodeRegistry.builtin

    private func docWithGroup() -> (ShaderDocument, GroupID, NodeID) {
        var def = GroupDefinition.make(name: "Fbm")
        def.inputs = [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                      SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)))]
        def.outputs = [SocketDecl(name: "value", type: .concrete(.float))]
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), position: CGPoint(x: 10, y: 20))
        doc.root.nodes[inst.id] = inst
        return (doc, def.id, inst.id)
    }

    @Test func builtinShapeMirrorsItsDefinition() throws {
        let def = try #require(reg["math.math"])
        let s = NodeShape(def: def)
        #expect(s.title == "Math" && s.category == .math && s.accent == nil)
        #expect(s.inputs.map(\.name) == ["a", "b"] && s.outputs.map(\.name) == ["out"])
        #expect(s.params.map(\.name) == ["op"] && s.generics["T"] != nil && s.style == .standard && !s.isPseudo)
    }

    @Test func instanceShapeComesFromTheDefinition() {
        let (doc, gid, iid) = docWithGroup()
        let s = doc.shape(of: iid, registry: reg)!
        #expect(s.title == "Fbm" && s.category == .group && s.accent == .purple)
        #expect(s.inputs.map(\.name) == ["uv", "scale"] && s.outputs.map(\.name) == ["value"])
        #expect(s.params.isEmpty && s.generics.isEmpty && !s.isPseudo)
        #expect(doc.node(iid)?.path == .root)
        #expect(doc.definitions[gid]?.name == "Fbm")
    }

    @Test func pseudoNodeShapesMirrorTheEnclosingDefinition() {
        let (doc, gid, _) = docWithGroup()
        let def = doc.definitions[gid]!
        let inShape = doc.shape(of: def.inputNode!, registry: reg)!
        let outShape = doc.shape(of: def.outputNode!, registry: reg)!
        #expect(inShape.title == "Group Input" && inShape.inputs.isEmpty && inShape.outputs.map(\.name) == ["uv", "scale"] && inShape.isPseudo)
        #expect(outShape.title == "Group Output" && outShape.outputs.isEmpty && outShape.inputs.map(\.name) == ["value"] && outShape.isPseudo)
        #expect(doc.node(def.inputNode!)?.path == .definition(gid))
    }

    @Test func makeCreatesBothPseudoNodesAndSubscriptMutatesTheRightGraph() {
        var doc = ShaderDocument()
        let def = GroupDefinition.make(name: "G")
        #expect(def.inputNode != nil && def.outputNode != nil && def.graph.nodes.count == 2)
        #expect(def.graph.nodes[def.inputNode!]?.position == CGPoint(x: 0, y: 0))
        doc.definitions[def.id] = def
        let n = NodeInstance(kind: .builtin("input.float"))
        doc[.definition(def.id)].nodes[n.id] = n
        #expect(doc.graph(at: .definition(def.id))?.nodes.count == 3)
        #expect(doc.root.nodes.isEmpty)
        #expect(doc.graph(at: .definition(GroupID())) == nil)
    }

    @Test func contentHashChangesWithNameSocketsOrGraph() {
        var a = GroupDefinition.make(name: "A")
        let h0 = a.contentHash
        #expect(h0 == a.contentHash)                      // deterministic
        a.name = "B"; let h1 = a.contentHash
        a.inputs.append(SocketDecl(name: "x", type: .concrete(.float))); let h2 = a.contentHash
        let n = NodeInstance(kind: .builtin("input.float")); a.graph.nodes[n.id] = n; let h3 = a.contentHash
        #expect(Set([h0, h1, h2, h3]).count == 4)
        #expect(h0.count == 16)
    }

    @Test func activePathPrefersTheStackThenTheEditedDefinition() {
        let (doc, gid, iid) = docWithGroup()
        var v = EditorViewState()
        #expect(v.activePath(in: doc) == .root)
        v.editingDefinition = gid
        #expect(v.activePath(in: doc) == .definition(gid))
        v.editingStack = [iid]
        #expect(v.activePath(in: doc) == .definition(gid))
        v.editingStack = [NodeID()]                       // a dangling instance falls back
        v.editingDefinition = nil
        #expect(v.activePath(in: doc) == .root)
    }

    @Test func viewStateDecodesWithoutTheNewKey() throws {
        let legacy = #"{"cameras":[],"editingStack":[],"viewer":null,"selection":[]}"#
        let v = try JSONDecoder().decode(EditorViewState.self, from: Data(legacy.utf8))
        #expect(v.editingDefinition == nil)
    }
}
```

`GroupDependenciesTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct GroupDependenciesTests {
    /// A ⊃ B ⊃ C (A's graph holds an instance of B, B's an instance of C).
    private func chain() -> (ShaderDocument, a: GroupID, b: GroupID, c: GroupID) {
        var a = GroupDefinition.make(name: "A"), b = GroupDefinition.make(name: "B"), c = GroupDefinition.make(name: "C")
        let ib = NodeInstance(kind: .group(b.id)); a.graph.nodes[ib.id] = ib
        let ic = NodeInstance(kind: .group(c.id)); b.graph.nodes[ic.id] = ic
        var doc = ShaderDocument()
        for d in [a, b, c] { doc.definitions[d.id] = d }
        let ia = NodeInstance(kind: .group(a.id)); doc.root.nodes[ia.id] = ia
        return (doc, a.id, b.id, c.id)
    }

    @Test func directAndTransitiveDependencies() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.direct(doc.definitions[a]!) == [b])
        #expect(GroupDependencies.transitive(a, in: doc) == [b, c])
        #expect(GroupDependencies.transitive(c, in: doc).isEmpty)
    }

    @Test func recursionIsRefusedDirectlyAndTransitively() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.wouldRecurse(placing: a, in: .definition(a), document: doc))
        #expect(GroupDependencies.wouldRecurse(placing: a, in: .definition(c), document: doc))   // C is inside A
        #expect(GroupDependencies.wouldRecurse(placing: b, in: .definition(c), document: doc))
        #expect(!GroupDependencies.wouldRecurse(placing: c, in: .definition(a), document: doc))
        #expect(!GroupDependencies.wouldRecurse(placing: a, in: .root, document: doc))
    }

    @Test func innerFirstOrderAndReachability() {
        let (doc, a, b, c) = chain()
        #expect(GroupDependencies.innerFirst([a, b, c], in: doc) == [c, b, a])
        #expect(GroupDependencies.reachable(from: doc.root, in: doc) == [a, b, c])
        #expect(GroupDependencies.reachable(from: doc.definitions[c]!.graph, in: doc).isEmpty)
    }
}
```

- [ ] **Step 2: Run to see them fail** — `swift test --package-path MetalNodesKit --filter "NodeShapeTests|GroupDependenciesTests"`: compile errors.

- [ ] **Step 3: Implement**

`NodeDef.swift`: `public enum NodeCategory: String, Codable, Sendable, CaseIterable { case input, math, vector, sdf, noise, color, utility, group, output }` — `group` sits before `output` so the palette lists "My Functions" before "Output". (Update `PaletteSearchTests`' category-order expectations when they break in T9 — Core does not touch them.)

`NodeShape.swift`:

```swift
import Foundation

/// What a node looks like to layout, wiring, typing and drawing (spec §20.2): a builtin's
/// definition, a group instance's exposed sockets, or a pseudo-node's mirror of its definition.
public struct NodeShape: Sendable, Hashable {
    public var title: String
    public var category: NodeCategory
    public var accent: DraculaAccent?
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var params: [ParamDecl]
    public var generics: [String: [SocketType]]
    public var style: NodeStyle
    /// `GroupInput` / `GroupOutput`: no params, no viewer badge, not deletable.
    public var isPseudo: Bool

    public init(title: String, category: NodeCategory, accent: DraculaAccent? = nil,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], style: NodeStyle = .standard, isPseudo: Bool = false) {
        self.title = title; self.category = category; self.accent = accent
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.style = style; self.isPseudo = isPseudo
    }

    public init(def: NodeDef) {
        self.init(title: def.title, category: def.category, inputs: def.inputs, outputs: def.outputs,
                  params: def.params, generics: def.generics, style: def.style)
    }

    public func input(named n: String) -> SocketDecl? { inputs.first { $0.name == n } }
    public func output(named n: String) -> SocketDecl? { outputs.first { $0.name == n } }
    public func param(named n: String) -> ParamDecl? { params.first { $0.name == n } }
}

public extension ShaderDocument {
    /// The shape of `node` as it appears in the graph at `path`. `nil` for an unknown builtin,
    /// a dangling instance, or a pseudo-node outside a definition.
    func shape(of node: NodeInstance, in path: GraphPath, registry: NodeRegistry) -> NodeShape? {
        switch node.kind {
        case .builtin(let id):
            return registry[id].map(NodeShape.init(def:))
        case .group(let gid):
            guard let d = definitions[gid] else { return nil }
            return NodeShape(title: d.name, category: .group, accent: d.accent, inputs: d.inputs, outputs: d.outputs)
        case .groupInput:
            guard case .definition(let gid) = path, let d = definitions[gid] else { return nil }
            return NodeShape(title: "Group Input", category: .group, accent: d.accent, outputs: d.inputs, isPseudo: true)
        case .groupOutput:
            guard case .definition(let gid) = path, let d = definitions[gid] else { return nil }
            return NodeShape(title: "Group Output", category: .group, accent: d.accent, inputs: d.outputs, isPseudo: true)
        }
    }

    func shape(of id: NodeID, registry: NodeRegistry) -> NodeShape? {
        guard let (n, path) = node(id) else { return nil }
        return shape(of: n, in: path, registry: registry)
    }
}
```

`ShaderDocument.swift` additions:

```swift
public extension GroupDefinition {
    /// A fresh definition with its two pseudo-nodes (spec §20.2): input at (0, 0), output at (600, 0).
    static func make(name: String, accent: DraculaAccent = .purple) -> GroupDefinition {
        var d = GroupDefinition(name: name, accent: accent)
        let i = NodeInstance(kind: .groupInput, position: CGPoint(x: 0, y: 0))
        let o = NodeInstance(kind: .groupOutput, position: CGPoint(x: 600, y: 0))
        d.graph.nodes[i.id] = i
        d.graph.nodes[o.id] = o
        return d
    }

    var inputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupInput }?.id }
    var outputNode: NodeID? { graph.nodes.values.first { $0.kind == .groupOutput }?.id }

    /// Identity of the definition's content (spec §20.7): name, sockets, accent and graph, ids included.
    var contentHash: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(self)) ?? Data()
        return ContentHash.fnv1a(data)
    }
}

public extension ShaderDocument {
    func graph(at path: GraphPath) -> Graph? {
        switch path {
        case .root: root
        case .definition(let id): definitions[id]?.graph
        }
    }

    /// Reads/mutates the graph at `path`. Writing to a missing definition is a programmer error.
    subscript(path: GraphPath) -> Graph {
        get { graph(at: path) ?? Graph() }
        set {
            switch path {
            case .root: root = newValue
            case .definition(let id):
                precondition(definitions[id] != nil, "no definition \(id)")
                definitions[id]!.graph = newValue
            }
        }
    }

    /// Ids are unique document-wide: find an instance in any graph.
    func node(_ id: NodeID) -> (node: NodeInstance, path: GraphPath)? {
        if let n = root.nodes[id] { return (n, .root) }
        for d in definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            if let n = d.graph.nodes[id] { return (n, .definition(d.id)) }
        }
        return nil
    }
}
```

`Groups/ContentHash.swift`:

```swift
import Foundation

/// 64-bit FNV-1a, hex. Deterministic across runs and platforms, which `Hasher` is not.
public enum ContentHash {
    public static func fnv1a(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for b in data { h ^= UInt64(b); h = h &* 0x100000001b3 }
        return String(format: "%016llx", h)
    }
}
```

`EditorViewState.swift` (the struct drops its synthesized `Codable`; the extension below supplies it):

```swift
public struct EditorViewState: Sendable, Hashable {
    public var cameras: [GraphPath: Camera] = [:]
    /// The instances dived through, outermost first (spec §4.2, §20.3).
    public var editingStack: [NodeID] = []
    /// A definition opened from the palette with no instance (spec §20.3).
    public var editingDefinition: GroupID? = nil
    public var viewer: SocketRef? = nil
    public var selection: Set<NodeID> = []
    public init() {}

    /// The graph the editor is bound to: the last dived instance's definition, else the edited
    /// definition, else the root. A dangling stack entry falls back rather than trapping.
    public func activePath(in doc: ShaderDocument) -> GraphPath {
        if let last = editingStack.last, let (n, _) = doc.node(last), case .group(let gid) = n.kind, doc.definitions[gid] != nil {
            return .definition(gid)
        }
        if let d = editingDefinition, doc.definitions[d] != nil { return .definition(d) }
        return .root
    }
}

extension EditorViewState: Codable {
    private enum Keys: String, CodingKey { case cameras, editingStack, editingDefinition, viewer, selection }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        cameras = try c.decodeIfPresent([GraphPath: Camera].self, forKey: .cameras) ?? [:]
        editingStack = try c.decodeIfPresent([NodeID].self, forKey: .editingStack) ?? []
        editingDefinition = try c.decodeIfPresent(GroupID.self, forKey: .editingDefinition)
        viewer = try c.decodeIfPresent(SocketRef.self, forKey: .viewer)
        selection = try c.decodeIfPresent(Set<NodeID>.self, forKey: .selection) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(cameras, forKey: .cameras); try c.encode(editingStack, forKey: .editingStack)
        try c.encodeIfPresent(editingDefinition, forKey: .editingDefinition)
        try c.encodeIfPresent(viewer, forKey: .viewer); try c.encode(selection, forKey: .selection)
    }
}
```

(`[GraphPath: Camera]` with an enum key encodes as an array of alternating key/value under synthesized Codable — the legacy fixture in the test uses `"cameras":[]` for that reason. If the existing persisted format differs, match what `GraphCodableTests`/the current encoder produce and adjust the fixture, never the decoder.)

`Groups/GroupDependencies.swift`:

```swift
import Foundation

/// Which definitions contain which (spec §4.6, §20.4).
public enum GroupDependencies {
    /// Definitions instantiated directly inside `def`.
    public static func direct(_ def: GroupDefinition) -> Set<GroupID> {
        Set(def.graph.nodes.values.compactMap { if case .group(let g) = $0.kind { return g } else { return nil } })
    }

    public static func transitive(_ id: GroupID, in doc: ShaderDocument) -> Set<GroupID> {
        var seen = Set<GroupID>(), stack = Array(doc.definitions[id].map(direct) ?? [])
        while let g = stack.popLast() {
            guard seen.insert(g).inserted else { continue }
            if let d = doc.definitions[g] { stack += direct(d) }
        }
        return seen
    }

    /// Would an instance of `target` inside the graph at `path` make some definition contain itself?
    public static func wouldRecurse(placing target: GroupID, in path: GraphPath, document doc: ShaderDocument) -> Bool {
        guard case .definition(let host) = path else { return false }
        return target == host || transitive(target, in: doc).contains(host)
    }

    /// Inner-most first: a definition follows everything it instantiates. Stable by id within a level.
    public static func innerFirst(_ ids: Set<GroupID>, in doc: ShaderDocument) -> [GroupID] {
        var out: [GroupID] = [], done = Set<GroupID>()
        func visit(_ g: GroupID) {
            guard !done.contains(g), let d = doc.definitions[g] else { return }
            done.insert(g)
            for dep in direct(d).sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) { visit(dep) }
            out.append(g)
        }
        for g in ids.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) { visit(g) }
        return out
    }

    /// Every definition instantiated in `graph`, transitively.
    public static func reachable(from graph: Graph, in doc: ShaderDocument) -> Set<GroupID> {
        var out = Set<GroupID>()
        for n in graph.nodes.values { if case .group(let g) = n.kind { out.insert(g); out.formUnion(transitive(g, in: doc)) } }
        return out
    }
}
```

- [ ] **Step 4: Run** the focused tests, then the full suite: green (existing `Validation` still refuses groups — unchanged until T2).

- [ ] **Step 5: Commit** — `feat(core): NodeShape, graph paths, GroupDefinition.make/contentHash, editingDefinition, GroupDependencies`

---

### Task 2: Validation and type resolution over shapes

**Files:**
- Modify: `Codegen/Validation.swift`, `Codegen/TypeResolver.swift`, `Codegen/ShaderGenerator.swift` (call sites only)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GroupValidationTests.swift`, `ValidationTests.swift` (the "groups not supported" test is replaced), `TypeResolverTests.swift`

**Interfaces:**
- Produces: `GraphValidator.validate(document:registry:target:) -> [Diagnostic]` (root + every definition); `GraphValidator.validate(graph:path:document:registry:target:)`; `GraphValidator.terminal(in:)` unchanged; `GraphValidator.isValidViewer(_:in document:registry:)` (any graph); `TypeResolver.resolve(_ graph:path:document:registry:order:)` with the old `resolve(_:registry:order:)` kept as a root-only convenience.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GroupValidationTests {
    let reg = NodeRegistry.builtin

    /// Root: Float → Fbm-like group (uv, scale → value) → Output. Definition: GroupInput.scale → Math(add) → GroupOutput.value.
    static func fixture() -> (ShaderDocument, GroupID, NodeID) {
        var def = GroupDefinition.make(name: "Twice")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        def.graph.nodes[math.id] = math
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(math.id, "a"))
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(math.id, "b"))
        def.graph.connect(SocketRef(math.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let f = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(0.25)])
        let inst = NodeInstance(kind: .group(def.id))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [f, inst, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst.id, "x"))
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        return (doc, def.id, inst.id)
    }

    @Test func aWellFormedGroupDocumentValidates() {
        let (doc, _, _) = Self.fixture()
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).isEmpty)
    }

    @Test func definitionsNeedExactlyOnePseudoNodeOfEachKind() {
        var (doc, gid, _) = Self.fixture()
        let extra = NodeInstance(kind: .groupOutput)
        doc.definitions[gid]!.graph.nodes[extra.id] = extra
        let d = GraphValidator.validate(document: doc, registry: reg, target: .fragment)
        #expect(d.contains { $0.message == "A definition may have only one Group Output" && $0.node == extra.id })
        doc.definitions[gid]!.graph.nodes[extra.id] = nil
        doc.definitions[gid]!.graph.nodes[doc.definitions[gid]!.inputNode!] = nil
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Definition “Twice” has no Group Input" })
    }

    @Test func pseudoNodesAreRefusedInTheRoot() {
        var (doc, _, _) = Self.fixture()
        let stray = NodeInstance(kind: .groupInput)
        doc.root.nodes[stray.id] = stray
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Group Input is only valid inside a definition" && $0.node == stray.id })
    }

    @Test func danglingInstanceAndRecursionAreDiagnosed() {
        var (doc, gid, inst) = Self.fixture()
        doc.root.nodes[inst.id]!.kind = .group(GroupID())
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "Group definition is missing" && $0.node == inst.id })
        let (doc2, gid2, _) = Self.fixture()
        var d2 = doc2
        let selfInst = NodeInstance(kind: .group(gid2))
        d2.definitions[gid2]!.graph.nodes[selfInst.id] = selfInst
        #expect(GraphValidator.validate(document: d2, registry: reg, target: .fragment).contains { $0.message == "Definition “Twice” contains itself" })
        _ = gid
    }

    @Test func wiresIntoAnInstanceAreCheckedAgainstItsShape() {
        var (doc, _, inst) = Self.fixture()
        let f = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst, "nope"))
        #expect(GraphValidator.validate(document: doc, registry: reg, target: .fragment).contains { $0.message == "No input socket named “nope” on Twice" })
    }

    @Test func typesResolveThroughGroupsAndPseudoNodes() {
        let (doc, gid, inst) = Self.fixture()
        let rootOrder = TopoSort.order(doc.root, from: GraphValidator.terminal(in: doc.root)!)
        let (root, d1) = TypeResolver.resolve(doc.root, path: .root, document: doc, registry: reg, order: rootOrder)
        #expect(d1.isEmpty && root[inst]?.inputTypes["x"] == .float && root[inst]?.outputTypes["out"] == .float)
        let def = doc.definitions[gid]!
        let order = TopoSort.order(def.graph, from: def.outputNode!)
        let (inner, d2) = TypeResolver.resolve(def.graph, path: .definition(gid), document: doc, registry: reg, order: order)
        #expect(d2.isEmpty && inner[def.inputNode!]?.outputTypes["x"] == .float && inner[def.outputNode!]?.inputTypes["out"] == .float)
        let math = def.graph.nodes.values.first { $0.kind == .builtin("math.math") }!
        #expect(inner[math.id]?.outputTypes["out"] == .float)
    }

    @Test func viewerValidityWorksInAnyGraph() {
        let (doc, gid, _) = Self.fixture()
        let def = doc.definitions[gid]!
        let math = def.graph.nodes.values.first { $0.kind == .builtin("math.math") }!
        #expect(GraphValidator.isValidViewer(SocketRef(math.id, "out"), in: doc, registry: reg))
        #expect(!GraphValidator.isValidViewer(SocketRef(def.outputNode!, "out"), in: doc, registry: reg))   // pseudo-node has no outputs
        #expect(GraphValidator.isValidViewer(SocketRef(def.inputNode!, "x"), in: doc, registry: reg))
    }
}
```

`ValidationTests.groupsAreNotYetSupported` → delete; the fixture above replaces it. Existing `ValidationTests` that call `GraphValidator.validate(graph, registry:, target:)` switch to `validate(document: doc, …)` with `doc.root = graph`.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`Validation.swift` — restructure:

```swift
public enum GraphValidator {
    public static let fragmentTerminalID = "output.fragment"

    public static func terminal(in graph: Graph) -> NodeID? { … unchanged … }

    /// The whole document: the root and every definition (spec §20.2, §20.4).
    public static func validate(document doc: ShaderDocument, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out = validate(graph: doc.root, path: .root, document: doc, registry: registry, target: target)
        for d in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            out += validate(graph: d.graph, path: .definition(d.id), document: doc, registry: registry, target: target)
            if GroupDependencies.transitive(d.id, in: doc).contains(d.id) || GroupDependencies.direct(d).contains(d.id) {
                out.append(Diagnostic(.error, "Definition “\(d.name)” contains itself"))
            }
        }
        return out
    }

    public static func validate(graph: Graph, path: GraphPath, document doc: ShaderDocument, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out: [Diagnostic] = []
        var shapes: [NodeID: NodeShape] = [:]
        let sorted = graph.nodes.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        for n in sorted {
            switch n.kind {
            case .builtin(let id) where registry[id] == nil:
                out.append(Diagnostic(.error, "Unknown node type “\(id)”", node: n.id))
            case .group(let g) where doc.definitions[g] == nil:
                out.append(Diagnostic(.error, "Group definition is missing", node: n.id))
            case .groupInput where path == .root:
                out.append(Diagnostic(.error, "Group Input is only valid inside a definition", node: n.id))
            case .groupOutput where path == .root:
                out.append(Diagnostic(.error, "Group Output is only valid inside a definition", node: n.id))
            default:
                if let s = doc.shape(of: n, in: path, registry: registry) { shapes[n.id] = s }
            }
        }

        // Terminals.
        switch path {
        case .root:
            let terminals = sorted.filter { $0.kind == .builtin(fragmentTerminalID) }
            if terminals.isEmpty { out.append(Diagnostic(.error, "Graph has no Fragment Output node")) }
            for extra in terminals.dropFirst() { out.append(Diagnostic(.error, "A graph may have only one Fragment Output", node: extra.id)) }
        case .definition(let gid):
            let name = doc.definitions[gid]?.name ?? "?"
            for n in sorted where n.kind == .builtin(fragmentTerminalID) {
                out.append(Diagnostic(.error, "Fragment Output is only valid in the root graph", node: n.id))
            }
            let ins = sorted.filter { $0.kind == .groupInput }, outs = sorted.filter { $0.kind == .groupOutput }
            if ins.isEmpty { out.append(Diagnostic(.error, "Definition “\(name)” has no Group Input")) }
            if outs.isEmpty { out.append(Diagnostic(.error, "Definition “\(name)” has no Group Output")) }
            for extra in ins.dropFirst() { out.append(Diagnostic(.error, "A definition may have only one Group Input", node: extra.id)) }
            for extra in outs.dropFirst() { out.append(Diagnostic(.error, "A definition may have only one Group Output", node: extra.id)) }
        }

        // Wire endpoints — same checks as before, against shapes.
        for (to, from) in graph.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) }) {
            guard let toShape = shapes[to.node] else {
                if graph.nodes[to.node] == nil { out.append(Diagnostic(.error, "Wire ends at a missing node")) }
                continue
            }
            guard let fromShape = shapes[from.node] else {
                if graph.nodes[from.node] == nil { out.append(Diagnostic(.error, "Wire starts at a missing node", node: to.node, socket: to.socket)) }
                continue
            }
            if toShape.input(named: to.socket) == nil {
                out.append(Diagnostic(.error, "No input socket named “\(to.socket)” on \(toShape.title)", node: to.node, socket: to.socket))
            }
            if fromShape.output(named: from.socket) == nil {
                out.append(Diagnostic(.error, "No output socket named “\(from.socket)” on \(fromShape.title)", node: from.node, socket: from.socket))
            }
        }

        // Cycles — unchanged (per graph).
        …

        // Required inputs and enum params — as before, iterating `shapes` instead of `defs`
        // (a `.required` input on a pseudo-node or instance reports "“label” must be connected" too).
        …
        return out
    }

    /// A viewer must name an existing node's output of a viewable (non-texture) type — in any graph.
    public static func isValidViewer(_ ref: SocketRef, in doc: ShaderDocument, registry: NodeRegistry) -> Bool {
        guard let s = doc.shape(of: ref.node, registry: registry), let decl = s.output(named: ref.socket) else { return false }
        if case .concrete(.texture) = decl.type { return false }
        return true
    }

    /// Root-only convenience, kept for existing callers.
    public static func isValidViewer(_ ref: SocketRef, in graph: Graph, registry: NodeRegistry) -> Bool {
        var d = ShaderDocument(); d.root = graph
        return isValidViewer(ref, in: d, registry: registry)
    }
}
```

`TypeResolver.swift`: replace the `guard … case .builtin … registry[defID]` with a shape lookup:

```swift
    public static func resolve(_ graph: Graph, path: GraphPath, document doc: ShaderDocument, registry: NodeRegistry, order: [NodeID])
        -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        …
        for id in order {
            guard let inst = graph.nodes[id], let def = doc.shape(of: inst, in: path, registry: registry) else { continue }
            … // body unchanged: `def.generics`, `def.inputs`, `def.outputs` now come from the shape
        }
    }

    /// Root-only convenience for existing callers.
    public static func resolve(_ graph: Graph, registry: NodeRegistry, order: [NodeID]) -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        var d = ShaderDocument(); d.root = graph
        return resolve(graph, path: .root, document: d, registry: registry, order: order)
    }
```

`ShaderGenerator.generate`/`diagnostics`: call `GraphValidator.validate(document: doc, …)` and `TypeResolver.resolve(doc.root, path: .root, document: doc, …)`; the viewer check uses the document overload. (Group nodes still won't *emit* until T3 — `Emitter` skips non-builtins today, so a group document generates without them; that's fine for this task's gate: `GroupValidationTests` only validate/resolve.)

- [ ] **Step 4: Run** the full suite — green.

- [ ] **Step 5: Commit** — `feat(core): validate the whole document and resolve types through NodeShape (groups, pseudo-nodes, recursion)`

---

### Task 3: Group function codegen

**Files:**
- Create: `Codegen/GroupCodegen.swift`
- Modify: `Codegen/Emitter.swift`, `Codegen/EmitEnvironment.swift`, `Codegen/ShaderGenerator.swift`, `Library/SampleDocuments.swift`
- Modify: `MetalNodesRender/UniformImage.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GroupCodegenTests.swift`, `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift`, `UniformImageTests.swift`

**Interfaces:**
- Produces: `GroupFunction { id, name, structName, inputs, outputs, uniformParams: [(path: ParamPath, type: SocketType)], requiredStdlib, source: String, lineOwners }`; `GroupCodegen.function(for:document:registry:functions:) -> GroupFunction` (view variants in T4); `GroupCodegen.parameterName(for: ParamPath) -> String` (`u_<8hex>_<param>`); `GroupCodegen.structName(_:)`/`functionName(_:)`; `EmitEnvironment.groupFunction`; `Emitter.emit(order:graph:path:document:registry:resolved:env:reserved:functions:)` whose `Output` gains `uniformRequests: [(path: ParamPath, type: SocketType)]`; `ShaderGenerator` emits `struct G_…_Out` + functions before the program; `ShaderDocument.sampleWithGroup()`; `UniformImage.rebuild` finds nodes in any graph and uses shapes.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

@Suite struct GroupCodegenTests {
    let reg = NodeRegistry.builtin

    /// Deterministic ids so the golden is stable.
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func gid(_ n: Int) -> GroupID { GroupID(raw: UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", n))!) }

    /// Definition "Twice": x (float, default 1) → Math add(x, x) → out. Root: Float(0.25) → Twice → Output.
    /// Math's `b` is wired too, so the only slots are: the root Float's value (p?) and nothing shared.
    private func twice() -> ShaderDocument {
        var def = GroupDefinition(id: gid(1), name: "Twice")
        let gin = NodeInstance(id: id(10), kind: .groupInput), gout = NodeInstance(id: id(11), kind: .groupOutput, position: CGPoint(x: 600, y: 0))
        def.graph.nodes[gin.id] = gin; def.graph.nodes[gout.id] = gout
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(id: id(12), kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        def.graph.nodes[math.id] = math
        def.graph.connect(SocketRef(gin.id, "x"), to: SocketRef(math.id, "a"))
        def.graph.connect(SocketRef(gin.id, "x"), to: SocketRef(math.id, "b"))
        def.graph.connect(SocketRef(math.id, "out"), to: SocketRef(gout.id, "out"))
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let f = NodeInstance(id: id(1), kind: .builtin("input.float"), params: ["value": .float(0.25)])
        let inst = NodeInstance(id: id(2), kind: .group(def.id))
        let out = NodeInstance(id: id(3), kind: .builtin("output.fragment"))
        for n in [f, inst, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(inst.id, "x"))
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        return doc
    }

    @Test func oneLevelGroupGolden() throws {
        let s = try ShaderGenerator.generate(twice(), registry: reg)
        let expected = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float2 resolution;
            float2 mouse;
            float time;
            float p0;
        };

        struct VertexOut {
            float4 position [[position]];
            float2 uv;
        };

        struct G_10000000_Out {
            float out;
        };

        G_10000000_Out mn_g_Twice_10000000(float2 uv, float time, float2 size, float2 mouse, float in_x) {
            float v0;
            v0 = in_x;
            float v1;
            v1 = v0 + v0;
            G_10000000_Out out;
            out.out = v1;
            return out;
        }

        fragment float4 shaderMain(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]]) {
            float v0;
            v0 = u.p0;
            G_10000000_Out r1 = mn_g_Twice_10000000(in.uv, u.time, u.resolution, u.mouse, v0);
            float v2;
            v2 = r1.out;
            return float4(float3(v2), 1.0);
        }

        """
        #expect(s.source == expected)
    }

    @Test func sharedAndPerInstanceSlots() throws {
        // Two instances of a definition whose internal Float param is unwired (shared slot) and
        // whose exposed input `x` is unwired on both instances (two per-instance slots).
        var def = GroupDefinition.make(name: "G")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let inner = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("multiply")])   // b unwired → shared
        def.graph.nodes[inner.id] = inner
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(inner.id, "a"))
        def.graph.connect(SocketRef(inner.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let i1 = NodeInstance(kind: .group(def.id), params: ["x": .float(2)]), i2 = NodeInstance(kind: .group(def.id))
        let add = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")]), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [i1, i2, add, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(i1.id, "out"), to: SocketRef(add.id, "a"))
        doc.root.connect(SocketRef(i2.id, "out"), to: SocketRef(add.id, "b"))
        doc.root.connect(SocketRef(add.id, "out"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        let paths = s.layout.fields.compactMap(\.path)
        #expect(paths.count == 3)
        #expect(paths.contains(ParamPath(node: i1.id, param: "x")) && paths.contains(ParamPath(node: i2.id, param: "x")))
        #expect(paths.contains(ParamPath(node: inner.id, param: "b")))
        #expect(s.source.contains("float in_x, float u_"))           // the shared slot is a function parameter
        #expect(s.source.components(separatedBy: "mn_g_G_").count == 4)   // one definition + two calls
    }

    @Test func nestedGroupsCallInnerFunctionsAndPropagateUniforms() throws {
        // Outer contains Inner; Inner has an unwired internal Float → its slot must appear in Outer's parameter list.
        var inner = GroupDefinition.make(name: "Inner")
        inner.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let f = NodeInstance(kind: .builtin("input.float"), params: ["value": .float(3)])
        inner.graph.nodes[f.id] = f
        inner.graph.connect(SocketRef(f.id, "out"), to: SocketRef(inner.outputNode!, "v"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let ii = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[ii.id] = ii
        outer.graph.connect(SocketRef(ii.id, "v"), to: SocketRef(outer.outputNode!, "v"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let io = NodeInstance(kind: .group(outer.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[io.id] = io; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(io.id, "v"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        let innerFn = s.source.range(of: "mn_g_Inner_")!.lowerBound, outerFn = s.source.range(of: "mn_g_Outer_")!.lowerBound
        #expect(innerFn < outerFn)                                        // inner-most first
        let pName = GroupCodegen.parameterName(for: ParamPath(node: f.id, param: "value"))
        #expect(s.source.contains("mn_g_Outer_\(GroupCodegen.hex8(outer.id))(float2 uv, float time, float2 size, float2 mouse, float \(pName))"))
        #expect(s.source.contains("u.p0);"))                              // the root call passes the slot
        #expect(s.layout.fields.compactMap(\.path) == [ParamPath(node: f.id, param: "value")])
    }

    @Test func groupCallsWorkUnderAStitchableTarget() throws {
        var doc = twice(); doc.settings.target = .stitchable(.colorEffect); doc.settings.exportName = "g"
        let s = try ShaderGenerator.generate(doc, target: doc.settings.target, registry: reg)
        #expect(s.exportSource!.contains("mn_g_Twice_10000000(uv, time, size, mouse, v0)"))
        #expect(s.exportSource!.range(of: "G_10000000_Out mn_g_Twice")!.lowerBound < s.exportSource!.range(of: "[[stitchable]]")!.lowerBound)
    }

    @Test func requiredStdlibOfInnerNodesIsIncludedOnce() throws {
        var def = GroupDefinition.make(name: "N")
        def.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        let noise = NodeInstance(kind: .builtin("noise.value"))
        def.graph.nodes[noise.id] = noise
        def.graph.connect(SocketRef(noise.id, "out"), to: SocketRef(def.outputNode!, "v"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let i1 = NodeInstance(kind: .group(def.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[i1.id] = i1; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(i1.id, "v"), to: SocketRef(out.id, "color"))
        let s = try ShaderGenerator.generate(doc, registry: reg)
        #expect(s.source.components(separatedBy: "float mn_valueNoise(").count == 2)
        #expect(s.source.range(of: "float mn_valueNoise(")!.lowerBound < s.source.range(of: "mn_g_N_")!.lowerBound)
    }

    @Test func sampleWithGroupGenerates() throws {
        let s = try ShaderGenerator.generate(ShaderDocument.sampleWithGroup(), registry: reg)
        #expect(s.source.contains("mn_g_"))
    }
}
```

`ShaderCompilerTests` additions (GPU):

```swift
    @Test func groupProgramsCompile() async throws {
        let c = try compiler()
        var doc = ShaderDocument.sampleWithGroup()
        for target in OutputTarget.all {
            doc.settings.target = target
            let shader = try ShaderGenerator.generate(doc, target: target)
            if case .failure(let msg, _, _) = await c.compile(shader, generation: 1) { Issue.record("\(target.title): \(msg)\n\(shader.source)") }
        }
    }
```

`UniformImageTests` addition:

```swift
    @Test func rebuildFillsSlotsInsideDefinitionsAndPerInstanceInputs() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let s = try ShaderGenerator.generate(doc)
        let img = UniformImage.rebuild(layout: s.layout, document: doc, registry: .builtin)
        // Every user slot has a node somewhere in the document.
        for f in s.layout.fields { if let p = f.path { #expect(doc.node(p.instancePath[0]) != nil) } }
        #expect(img.bytes.count == s.layout.totalSize)
    }
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`EmitEnvironment.swift` — add:

```swift
    /// Inside a group function (spec §20.4): uniforms are parameters named after their slot's
    /// path, so the function is the same whatever the caller's target.
    public static let groupFunction = EmitEnvironment(
        uniform: { f in
            guard let p = f.path else { return f.name }
            return GroupCodegen.parameterName(for: p)
        },
        sys: ["uv": "uv", "time": "time", "resolution": "size", "mouse": "mouse"])
```

`GroupCodegen.swift`:

```swift
import Foundation

/// One MSL function per definition (spec §20.4).
public struct GroupFunction: Sendable {
    public let id: GroupID
    public let name: String
    public let structName: String
    public let inputs: [SocketDecl]
    public let outputs: [SocketDecl]
    /// Every uniform slot the body reads, own and propagated, in first-use order. These are the
    /// function's trailing parameters and become requests of whoever calls it.
    public let uniformParams: [(path: ParamPath, type: SocketType)]
    public let requiredStdlib: [String]
    public let source: String
    /// Line owners for the function's body statements, parallel to the body lines in `source`
    /// (the signature and the struct lines have no owner).
    public let lineOwners: [NodeID?]
}

public enum GroupCodegen {
    public static func hex8(_ id: GroupID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }
    public static func hex8(_ id: NodeID) -> String { String(id.raw.uuidString.prefix(8)).lowercased() }

    public static func functionName(_ def: GroupDefinition) -> String {
        "mn_g_\(StitchableCodegen.sanitizedName(def.name))_\(hex8(def.id))"
    }
    public static func structName(_ id: GroupID) -> String { "G_\(hex8(id))_Out" }

    /// `u_<8 hex of the node>_<param>` — stable, target-agnostic, unique per slot.
    public static func parameterName(for path: ParamPath) -> String {
        let node = path.instancePath.first.map(hex8) ?? "0"
        return "u_\(node)_\(StitchableCodegen.sanitizedName(path.param))"
    }

    /// Emits `def`'s function. `functions` must already hold every definition `def` instantiates.
    /// `viewOutput` (T4) replaces the outputs with one field `value` for the viewed socket.
    static func function(for def: GroupDefinition, document doc: ShaderDocument, registry: NodeRegistry,
                         functions: [GroupID: GroupFunction], viewOutput: SocketRef? = nil) throws(GenerationError) -> GroupFunction {
        let path = GraphPath.definition(def.id)
        guard let outNode = def.outputNode else { throw .invalid([Diagnostic(.error, "Definition “\(def.name)” has no Group Output")]) }
        let start = viewOutput?.node ?? outNode
        let order = TopoSort.order(def.graph, from: start)
        let (resolved, diags) = TypeResolver.resolve(def.graph, path: path, document: doc, registry: registry, order: order)
        if !diags.isEmpty { throw .invalid(diags) }
        let emitted = Emitter.emit(order: order, graph: def.graph, path: path, document: doc, registry: registry,
                                   resolved: resolved, env: .groupFunction, reserved: [], functions: functions)

        let outputs: [SocketDecl] = viewOutput.map { v in
            [SocketDecl(name: "value", type: .concrete(resolved[v.node]?.outputTypes[v.socket] ?? .float))]
        } ?? def.outputs
        let name = viewOutput == nil ? functionName(def) : functionName(def) + "_view"
        let structName = viewOutput == nil ? structName(def.id) : structName(def.id).replacingOccurrences(of: "_Out", with: "_View")

        var b = SourceBuilder()
        b.add("struct \(structName) {")
        for o in outputs { b.add("    \(concrete(o.type).mslName) \(o.name);") }
        b.add("};\n")
        var params = ["float2 uv", "float time", "float2 size", "float2 mouse"]
        params += def.inputs.map { "\(concrete($0.type).mslName) in_\($0.name)" }
        params += emitted.uniformRequests.map { "\($0.type.mslName) \(parameterName(for: $0.path))" }
        b.add("\(structName) \(name)(\(params.joined(separator: ", "))) {")
        var owners: [NodeID?] = []
        for (i, line) in emitted.bodyLines.enumerated() { b.add("    " + line, owner: emitted.lineOwners[i]); owners.append(emitted.lineOwners[i]) }
        b.add("    \(structName) out;")
        if let v = viewOutput {
            let expr = emitted.outputVars[v] ?? "0.0"
            b.add("    out.value = \(expr);")
        } else {
            let exprs = emitted.inputExpressions[outNode] ?? [:]
            for o in def.outputs { b.add("    out.\(o.name) = \(exprs[o.name] ?? zeroLiteral(concrete(o.type)));") }
        }
        b.add("    return out;")
        b.add("}")
        return GroupFunction(id: def.id, name: name, structName: structName, inputs: def.inputs, outputs: outputs,
                             uniformParams: emitted.uniformRequests, requiredStdlib: emitted.requiredStdlib,
                             source: b.text, lineOwners: owners)
    }

    static func concrete(_ t: TypeRef) -> SocketType { if case .concrete(let c) = t { return c } else { return .float } }

    static func zeroLiteral(_ t: SocketType) -> String {
        switch t {
        case .float: "0.0"; case .float2: "float2(0.0)"; case .float3: "float3(0.0)"
        case .float4, .color: "float4(0.0, 0.0, 0.0, 1.0)"; case .int: "0"; case .bool: "false"; case .texture: "0.0"
        }
    }
}
```

`Emitter.swift` — the new signature and the three node kinds:

```swift
    static func emit(order: [NodeID], graph: Graph, path: GraphPath = .root, document doc: ShaderDocument? = nil,
                     registry: NodeRegistry, resolved: [NodeID: ResolvedNode],
                     env: EmitEnvironment = .fragment,
                     reserved: [UniformLayoutBuilder.Reserved] = UniformLayoutBuilder.standardReserved,
                     functions: [GroupID: GroupFunction] = [:]) -> Output {
        let doc = doc ?? { var d = ShaderDocument(); d.root = graph; return d }()
        func shape(_ inst: NodeInstance) -> NodeShape? { doc.shape(of: inst, in: path, registry: registry) }
```

Pass 1 (requests) becomes, per node:
- builtin: as today (via `registry[defID]` for `body`/`referencedNames`; the shape gives `inputs`/`params`).
- `.group(gid)`: for each exposed input `decl` with `graph.inputs[SocketRef(id, decl.name)] == nil` and `case .value = decl.default` → request `(ParamPath(node: id, param: decl.name), concrete(decl.type))`; then for each `functions[gid]!.uniformParams` → request it too (dedup: keep a `Set<ParamPath>`).
- `.groupOutput`: like a builtin's inputs: unwired inputs with `.value` defaults → request `(ParamPath(node: id, param: decl.name), type)`.
- `.groupInput`: nothing.
Record the deduplicated request list in `out.uniformRequests` (before the layout is built; the layout is built from it).

Pass 2, per node:
- `.groupInput`: for each output decl: `out.outputVars[SocketRef(id, decl.name)] = "in_\(decl.name)"` — no lines.
- `.groupOutput`: compute `inputs` exactly like a builtin (wired → converted var; unwired `.value` → `uniformExpr(path)`; `.required` → `"/* unconnected */"`; `.uv` → sys uv) and store `out.inputExpressions[id] = inputs`; no lines.
- `.group(gid)`: `let fn = functions[gid]!`; input expressions like a builtin (from the shape's inputs, converted; unwired → uniformExpr for its per-instance/shared slot); `let r = "r\(varCounter)"; varCounter += 1`; line `"\(fn.structName) \(r) = \(fn.name)(\(env.sys["uv"]!), \(env.sys["time"]!), \(env.sys["resolution"]!), \(env.sys["mouse"]!), <inputs in fn.inputs order>, <fn.uniformParams.map { uniformExpr($0.path) }>);"` owned by `id`; then for each output decl: `"\(type.mslName) v\(k);"` and `"v\(k) = \(r).\(decl.name);"` with `outputVars[SocketRef(id, decl.name)] = "v\(k)"` (two lines per output, matching the golden).
- builtin: unchanged.

`ShaderGenerator.generate`: after type resolution of the root:

```swift
        let reachable = GroupDependencies.reachable(from: doc.root, in: doc)
        var functions: [GroupID: GroupFunction] = [:]
        for gid in GroupDependencies.innerFirst(reachable, in: doc) {
            functions[gid] = try GroupCodegen.function(for: doc.definitions[gid]!, document: doc, registry: registry, functions: functions)
        }
```

and pass `functions` (and `path: .root, document: doc`) to both `assembleFragment` and `assembleStitchable`'s `Emitter.emit` calls. Both assemblers add, after the stdlib block and before the program: for each `gid` in the same inner-first order, `b.add(functions[gid]!.source)` (the function source already ends with `}` + newline; `add` appends one more newline, producing the blank line the golden shows). The stdlib closure = `MSLStdlib.resolve(emitted.requiredStdlib + functions.values.flatMap(\.requiredStdlib))`. For the stitchable export, functions go into `export` too (before the stitchable function).

Line map: function bodies' owners are their inner node ids — `SourceBuilder.add(fn.source)` adds the whole function as one chunk without owners; acceptable for M4 (compile errors inside a definition map to no node; the diagnostic still shows in the pane). Note it in the report.

`SampleDocuments.swift` — `sampleWithGroup()`: the M1 sample with the two Math nodes (Multiply, Sine) and the Float grouped into a definition "Wobble" (inputs: `time` float2? no — `t` float from Time; outputs: `out` float), built by hand with the same wiring as `sample()` plus one shared internal slot (the Float's value stays inside the group) so the GPU test covers a shared slot and a wired exposed input.

`UniformImage.rebuild`:

```swift
        for f in layout.fields {
            guard let path = f.path, let nodeID = path.instancePath.first,
                  let (inst, gpath) = document.node(nodeID),
                  let shape = document.shape(of: inst, in: gpath, registry: registry) else { continue }
            if let v = inst.params[path.param] { img.write(v, into: f) }
            else if let decl = shape.input(named: path.param), case .value(let v) = decl.default { img.write(v, into: f) }
            else if let p = shape.param(named: path.param) { img.write(p.defaultValue, into: f) }
        }
```

- [ ] **Step 4: Run** the suite; then `--filter ShaderCompilerTests` on the GPU (`groupProgramsCompile` for all four targets). If MSL rejects a struct-return detail, fix the generator, not the golden's intent (adjust the golden text only to the exact produced output when §20.4 does not pin the detail).

- [ ] **Step 5: Commit** — `feat(core): one MSL function per definition — group calls, shared/per-instance slots, nested propagation, stitchable export`

---

### Task 4: Viewer inside a definition

**Files:**
- Modify: `Codegen/GroupCodegen.swift`, `Codegen/ShaderGenerator.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GroupViewerTests.swift`, `ShaderCompilerTests.swift`

**Interfaces:**
- Produces: `ShaderGenerator.generate(_:target:viewer:viewerPath:viewerDefinition:registry:)` (`viewerPath: [NodeID] = []`, `viewerDefinition: GroupID? = nil`); view variants (`…_view` functions with a single `value` field); `GeneratedShader.viewerPath`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GroupViewerTests {
    let reg = NodeRegistry.builtin

    /// Root: Float → Outer → Output; Outer: GroupInput.x → Inner → GroupOutput; Inner: GroupInput.x → Math(add) → GroupOutput.
    private func nested() -> (doc: ShaderDocument, outerInst: NodeID, innerInst: NodeID, math: NodeID, inner: GroupID) {
        var inner = GroupDefinition.make(name: "Inner")
        inner.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        inner.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        inner.graph.nodes[math.id] = math
        inner.graph.connect(SocketRef(inner.inputNode!, "x"), to: SocketRef(math.id, "a"))
        inner.graph.connect(SocketRef(math.id, "out"), to: SocketRef(inner.outputNode!, "out"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.inputs = inner.inputs; outer.outputs = inner.outputs
        let ii = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[ii.id] = ii
        outer.graph.connect(SocketRef(outer.inputNode!, "x"), to: SocketRef(ii.id, "x"))
        outer.graph.connect(SocketRef(ii.id, "out"), to: SocketRef(outer.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let f = NodeInstance(kind: .builtin("input.float")), io = NodeInstance(kind: .group(outer.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [f, io, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(io.id, "x"))
        doc.root.connect(SocketRef(io.id, "out"), to: SocketRef(out.id, "color"))
        return (doc, io.id, ii.id, math.id, inner.id)
    }

    @Test func viewingInsideANestedDefinitionThroughTheDivedInstances() throws {
        let (doc, io, ii, math, _) = nested()
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [io, ii], registry: reg)
        #expect(s.target == .fragment && s.viewer == SocketRef(math, "out"))
        #expect(s.source.contains("_view("))                          // view variants exist
        #expect(s.source.contains("mn_g_Outer_") && s.source.contains("mn_g_Inner_"))
        #expect(s.source.contains("u.viewerMin"))
        #expect(s.source.contains(".value;"))                         // the root reads the view value
        #expect(!s.source.contains("return float4(v"))                // the Output node is not the terminal
    }

    @Test func viewingFromThePaletteUsesDeclaredDefaults() throws {
        let (doc, _, _, math, inner) = nested()
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerDefinition: inner, registry: reg)
        #expect(s.source.contains("_view(in.uv, u.time, u.resolution, u.mouse, 1.0"))   // x's declared default as a literal
        #expect(s.layout.fields.compactMap(\.path).isEmpty)                             // no per-instance slots
        #expect(s.source.contains("u.viewerMin"))
    }

    @Test func aBrokenPathIsADiagnostic() {
        let (doc, io, _, math, _) = nested()
        #expect(throws: GenerationError.invalid([Diagnostic(.error, "The viewed instance no longer exists")])) {
            try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [io, NodeID()], registry: reg)
        }
    }
}
```

GPU: extend `groupProgramsCompile` (or add `groupViewerProgramsCompile`) to compile the two viewer programs above.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`ShaderGenerator.generate` gains `viewerPath: [NodeID] = [], viewerDefinition: GroupID? = nil`:

- Validate: every id in `viewerPath` must be a `.group` instance (`doc.node`), each inside the previous one's definition (the first in the root) — else `.invalid([Diagnostic(.error, "The viewed instance no longer exists")])`. A viewer must be valid document-wide (`isValidViewer(_:in doc:…)`).
- Case A — `viewer == nil` or (`viewerPath.isEmpty && viewerDefinition == nil`): as today (the viewer must then be in the root).
- Case B — `viewerPath` non-empty: let `chain = viewerPath.map { instance → definition }`. Build normal functions for every reachable definition (T3). Then build view variants **inner-most first**: for the last definition, `GroupCodegen.function(for:…, viewOutput: viewer)`; for each outer one, `function(for:…, functions: functionsWithInnerVariant, viewOutput: SocketRef(nextInstance, "value"))` where `functionsWithInnerVariant` maps the *next definition's id* to its **view variant** (so the call inside the outer variant targets `…_view` and its struct field `value`). Root program: order = `TopoSort.order(doc.root, from: viewerPath[0])`; emit with `functions` where the first definition maps to its view variant; wrap `outputVars[SocketRef(viewerPath[0], "value")]` with `ViewerWrap` for the viewed type; reserved = `viewerReserved`. Add all variant sources after the normal functions.
- Case C — `viewerDefinition` set, path empty: build the definition's view variant (normal functions for its dependencies), then a synthetic root program: `"\(structName) r0 = \(variant.name)(in.uv, u.time, u.resolution, u.mouse, <defaults>, <uniform params>);"` where each exposed input's default is `SocketDefault.value(v) → v.mslLiteral`, `.uv → in.uv`, `.required → zeroLiteral`, and the variant's `uniformParams` are requested into the layout and spelled with `env.fragment.uniform`; then `"<T> v0 = r0.value;"` and the wrap.

`GeneratedShader` gains `viewerPath: [NodeID]` (default `[]`).

- [ ] **Step 4: Run** suite + GPU.

- [ ] **Step 5: Commit** — `feat(core): viewer inside a definition — view variants through the dived instances, palette defaults`

---

### Task 5: Group operations

**Files:**
- Create: `Groups/GroupOperations.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GroupOperationsTests.swift`

**Interfaces:**
- Produces: `SocketKind { input, output }`; `GroupOperations.group(_ ids:in:of:registry:resolved:name:) -> (document: ShaderDocument, definition: GroupID, instance: NodeID)?`; `ungroup(_:in:of:) -> (document:, nodes: Set<NodeID>)?`; `makeUnique(_:in:of:) -> (document:, definition: GroupID)?`; `rename(_:to:in:)`; `setAccent(_:_:in:)`; `renameSocket(_:kind:from:to:in:) -> ShaderDocument?`; `removeSocket(_:kind:name:in:) -> ShaderDocument?`; `addSocket(_:kind:decl:in:) -> ShaderDocument?`; `deleteDefinition(_:in:) -> ShaderDocument?` (only when unused); `uniqueDefinitionName(_:in:)`, `uniqueSocketName(_:among:)`; `isUsed(_:in:)`.

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct GroupOperationsTests {
    let reg = NodeRegistry.builtin

    /// The M1 sample; select {mul, sine} (Time and Float feed mul; sine feeds Combine.z).
    private func sample() -> (ShaderDocument, mul: NodeID, sine: NodeID, time: NodeID, speed: NodeID, comb: NodeID) {
        let doc = ShaderDocument.sample()
        func find(_ id: String, _ op: String? = nil) -> NodeID {
            doc.root.nodes.values.first { $0.kind == .builtin(id) && (op == nil || $0.params["op"] == .enumCase(op!)) }!.id
        }
        return (doc, find("math.math", "multiply"), find("math.math", "sine"), find("input.time"), find("input.float"), find("vector.combine"))
    }

    private func resolved(_ doc: ShaderDocument) -> [NodeID: ResolvedNode] { (try? ShaderGenerator.generate(doc))?.resolved ?? [:] }

    @Test func groupCutsTheBoundaryAndDedupesBySourceSocket() throws {
        let (doc, mul, sine, time, speed, comb) = sample()
        let r = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let def = r.document.definitions[r.definition]!
        #expect(def.name == "Group")
        #expect(def.inputs.map(\.name) == ["time", "out"])           // Time.time and Float.out — one each
        #expect(def.inputs.map { GroupCodegen.concrete($0.type) } == [.float, .float])
        #expect(def.outputs.map(\.name) == ["out"])                    // sine.out → Combine.z
        #expect(def.graph.nodes.count == 4)                            // 2 nodes + 2 pseudo
        // Rewired externally:
        #expect(r.document.root.inputs[SocketRef(r.instance, "time")] == SocketRef(time, "time"))
        #expect(r.document.root.inputs[SocketRef(r.instance, "out")] == SocketRef(speed, "out"))
        #expect(r.document.root.inputs[SocketRef(comb, "z")] == SocketRef(r.instance, "out"))
        #expect(r.document.root.nodes[mul] == nil && r.document.root.nodes[sine] == nil)
        // Internally: GroupInput.time → mul.a, GroupInput.out → mul.b, mul.out → sine.a, sine.out → GroupOutput.out.
        #expect(def.graph.inputs[SocketRef(mul, "a")] == SocketRef(def.inputNode!, "time"))
        #expect(def.graph.inputs[SocketRef(def.outputNode!, "out")] == SocketRef(sine, "out"))
        #expect(GraphValidator.validate(document: r.document, registry: reg, target: .fragment).isEmpty)
        #expect(try ShaderGenerator.generate(r.document).source.contains("mn_g_Group_"))
    }

    @Test func oneExternalSourceFeedingTwoSelectedNodesIsOneInput() throws {
        var doc = ShaderDocument()
        let src = NodeInstance(kind: .builtin("input.float")), a = NodeInstance(kind: .builtin("math.math")), b = NodeInstance(kind: .builtin("math.math"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [src, a, b, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(a.id, "a"))
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(b.id, "a"))
        doc.root.connect(SocketRef(a.id, "out"), to: SocketRef(out.id, "color"))
        let r = try #require(GroupOperations.group([a.id, b.id], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: "Pair"))
        let def = r.document.definitions[r.definition]!
        #expect(def.inputs.count == 1 && def.inputs[0].name == "out")
        #expect(def.graph.inputs[SocketRef(a.id, "a")] == SocketRef(def.inputNode!, "out"))
        #expect(def.graph.inputs[SocketRef(b.id, "a")] == SocketRef(def.inputNode!, "out"))
    }

    @Test func groupThenUngroupIsIdentityModuloIDs() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let u = try #require(GroupOperations.ungroup(g.instance, in: .root, of: g.document))
        #expect(u.document.root.nodes.count == doc.root.nodes.count)
        #expect(u.document.root.inputs.count == doc.root.inputs.count)
        #expect(u.nodes.count == 2)
        // Same multiset of (kind, params) and same wiring shape.
        func signature(_ g: Graph) -> [String] {
            g.inputs.map { to, from in
                let tk = g.nodes[to.node]!.kind, fk = g.nodes[from.node]!.kind
                return "\(fk).\(from.socket)->\(tk).\(to.socket)"
            }.sorted()
        }
        #expect(signature(u.document.root) == signature(doc.root))
        #expect(u.document.definitions.count == 1)                    // the definition is kept (spec §20.6)
        #expect(try ShaderGenerator.generate(u.document).source == (try ShaderGenerator.generate(doc).source))
    }

    @Test func ungroupCarriesUnwiredExposedValuesOntoTheInlinedNodes() throws {
        var def = GroupDefinition.make(name: "G")
        def.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let m = NodeInstance(kind: .builtin("math.math"))
        def.graph.nodes[m.id] = m
        def.graph.connect(SocketRef(def.inputNode!, "x"), to: SocketRef(m.id, "a"))
        def.graph.connect(SocketRef(m.id, "out"), to: SocketRef(def.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), params: ["x": .float(7)]), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[inst.id] = inst; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        let u = try #require(GroupOperations.ungroup(inst.id, in: .root, of: doc))
        let inlined = u.document.root.nodes[u.nodes.first!]!
        #expect(inlined.params["a"] == .float(7))
        #expect(u.document.root.inputs[SocketRef(out.id, "color")]?.node == inlined.id)
    }

    @Test func makeUniqueRetargetsOnlyThatInstance() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        var d = g.document
        let second = NodeInstance(kind: .group(g.definition), position: CGPoint(x: 900, y: 900))
        d.root.nodes[second.id] = second
        let m = try #require(GroupOperations.makeUnique(second.id, in: .root, of: d))
        #expect(m.definition != g.definition)
        #expect(m.document.definitions[m.definition]?.name == "Group 2")
        #expect(m.document.root.nodes[second.id]?.kind == .group(m.definition))
        #expect(m.document.root.nodes[g.instance]?.kind == .group(g.definition))
        let ids = Set(m.document.definitions[m.definition]!.graph.nodes.keys), orig = Set(m.document.definitions[g.definition]!.graph.nodes.keys)
        #expect(ids.isDisjoint(with: orig))
    }

    @Test func renameSocketRewritesEveryReference() throws {
        let (doc, mul, sine, time, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let r = try #require(GroupOperations.renameSocket(g.definition, kind: .input, from: "time", to: "t", in: g.document))
        let def = r.definitions[g.definition]!
        #expect(def.inputs.map(\.name) == ["t", "out"])
        #expect(r.root.inputs[SocketRef(g.instance, "t")] == SocketRef(time, "time") && r.root.inputs[SocketRef(g.instance, "time")] == nil)
        #expect(def.graph.inputs[SocketRef(mul, "a")] == SocketRef(def.inputNode!, "t"))
        #expect(GroupOperations.renameSocket(g.definition, kind: .input, from: "t", to: "out", in: r) == nil)   // clash
        #expect(GroupOperations.renameSocket(g.definition, kind: .input, from: "t", to: "2 bad", in: r)?.definitions[g.definition]?.inputs.first?.name == "_2_bad")
    }

    @Test func removeSocketDeletesOrphansEverywhere() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let r = try #require(GroupOperations.removeSocket(g.definition, kind: .input, name: "time", in: g.document))
        #expect(r.definitions[g.definition]!.inputs.map(\.name) == ["out"])
        #expect(r.root.inputs[SocketRef(g.instance, "time")] == nil)
        #expect(r.definitions[g.definition]!.graph.inputs[SocketRef(mul, "a")] == nil)
        #expect(GraphValidator.validate(document: r, registry: reg, target: .fragment).isEmpty)
    }

    @Test func groupingRefusesPseudoNodesAndRecursion() throws {
        let (doc, mul, sine, _, _, _) = sample()
        let g = try #require(GroupOperations.group([mul, sine], in: .root, of: doc, registry: reg, resolved: resolved(doc), name: nil))
        let def = g.document.definitions[g.definition]!
        #expect(GroupOperations.group([mul, def.inputNode!], in: .definition(g.definition), of: g.document, registry: reg, resolved: [:], name: nil) == nil)
        #expect(GroupOperations.group([mul], in: .definition(g.definition), of: g.document, registry: reg, resolved: [:], name: nil) != nil)  // nested group inside is fine
    }

    @Test func namesAreUnique() {
        var doc = ShaderDocument()
        let a = GroupDefinition.make(name: "Group"); doc.definitions[a.id] = a
        #expect(GroupOperations.uniqueDefinitionName("Group", in: doc) == "Group 2")
        #expect(GroupOperations.uniqueSocketName("out", among: ["out", "out2"]) == "out3")
        #expect(GroupOperations.isUsed(a.id, in: doc) == false)
        #expect(GroupOperations.deleteDefinition(a.id, in: doc)?.definitions.isEmpty == true)
    }
}
```

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement** `Groups/GroupOperations.swift` — the algorithms of spec §20.6, written out:

```swift
import Foundation
import CoreGraphics

public enum SocketKind: Sendable, Hashable { case input, output }

/// The five operations (spec §4, §20.6) as pure document transforms.
public enum GroupOperations {
    static let internalOffset = CGPoint(x: 220, y: 0)

    public static func isUsed(_ id: GroupID, in doc: ShaderDocument) -> Bool {
        func has(_ g: Graph) -> Bool { g.nodes.values.contains { $0.kind == .group(id) } }
        return has(doc.root) || doc.definitions.values.contains { has($0.graph) }
    }

    public static func uniqueDefinitionName(_ base: String, in doc: ShaderDocument) -> String {
        let names = Set(doc.definitions.values.map(\.name))
        if !names.contains(base) { return base }
        var n = 2
        while names.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    public static func uniqueSocketName(_ base: String, among existing: [String]) -> String {
        let b = StitchableCodegen.sanitizedName(base)
        if !existing.contains(b) { return b }
        var n = 2
        while existing.contains("\(b)\(n)") { n += 1 }
        return "\(b)\(n)"
    }

    public static func group(_ ids: Set<NodeID>, in path: GraphPath, of doc: ShaderDocument, registry: NodeRegistry,
                             resolved: [NodeID: ResolvedNode], name: String?) -> (document: ShaderDocument, definition: GroupID, instance: NodeID)? {
        let g = doc[path]
        let picked = ids.compactMap { g.nodes[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        guard picked.count == ids.count, !picked.isEmpty,
              !picked.contains(where: { $0.kind == .groupInput || $0.kind == .groupOutput }) else { return nil }
        // Recursion: grouping inside definition D a selection that instantiates an ancestor of D is impossible
        // by construction (D would already contain itself), but a nested instance of D itself must be refused.
        if case .definition(let host) = path, picked.contains(where: { $0.kind == .group(host) }) { return nil }

        func outType(_ ref: SocketRef) -> SocketType {
            if let t = resolved[ref.node]?.outputTypes[ref.socket] { return t }
            if let s = doc.shape(of: g.nodes[ref.node]!, in: path, registry: registry), let d = s.output(named: ref.socket),
               case .concrete(let c) = d.type { return c }
            return .float
        }

        var def = GroupDefinition.make(name: uniqueDefinitionName(name ?? "Group", in: doc))
        let gin = def.inputNode!, gout = def.outputNode!
        let minX = picked.map(\.position.x).min()!, minY = picked.map(\.position.y).min()!
        let maxX = picked.map(\.position.x).max()!
        for n in picked {
            var m = n
            m.position = CGPoint(x: n.position.x - minX + internalOffset.x, y: n.position.y - minY + internalOffset.y)
            def.graph.nodes[m.id] = m
        }
        def.graph.nodes[gout]!.position = CGPoint(x: maxX - minX + internalOffset.x + 260, y: 0)
        for e in g.internalEdges(among: ids) { def.graph.connect(e.from, to: e.to) }

        // Inbound: to ∈ S, from ∉ S — one input per distinct source socket.
        var inputBySource: [SocketRef: String] = [:]
        for (to, from) in g.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) })
        where ids.contains(to.node) && !ids.contains(from.node) {
            let name = inputBySource[from] ?? {
                let n = uniqueSocketName(from.socket, among: def.inputs.map(\.name))
                let t = outType(from)
                def.inputs.append(SocketDecl(name: n, type: .concrete(t), default: .value(zero(t))))
                inputBySource[from] = n
                return n
            }()
            def.graph.connect(SocketRef(gin, name), to: to)
        }
        // Outbound: from ∈ S, to ∉ S — one output per distinct internal source socket.
        var outputBySource: [SocketRef: String] = [:]
        for (to, from) in g.inputs.sorted(by: { ($0.key.node.raw.uuidString, $0.key.socket) < ($1.key.node.raw.uuidString, $1.key.socket) })
        where ids.contains(from.node) && !ids.contains(to.node) {
            if outputBySource[from] == nil {
                let n = uniqueSocketName(from.socket, among: def.outputs.map(\.name))
                def.outputs.append(SocketDecl(name: n, type: .concrete(outType(from))))
                outputBySource[from] = n
                def.graph.connect(from, to: SocketRef(gout, n))
            }
        }

        var out = doc
        out.definitions[def.id] = def
        var graph = g
        graph.remove(nodes: ids)
        let inst = NodeInstance(kind: .group(def.id), position: CGPoint(x: minX, y: minY))
        graph.nodes[inst.id] = inst
        for (from, name) in inputBySource { graph.connect(from, to: SocketRef(inst.id, name)) }
        for (to, from) in g.inputs where ids.contains(from.node) && !ids.contains(to.node) {
            graph.connect(SocketRef(inst.id, outputBySource[from]!), to: to)
        }
        out[path] = graph
        return (out, def.id, inst.id)
    }

    public static func ungroup(_ instance: NodeID, in path: GraphPath, of doc: ShaderDocument) -> (document: ShaderDocument, nodes: Set<NodeID>)? {
        var g = doc[path]
        guard let inst = g.nodes[instance], case .group(let gid) = inst.kind, let def = doc.definitions[gid],
              let gin = def.inputNode, let gout = def.outputNode else { return nil }
        var map: [NodeID: NodeID] = [:]
        for n in def.graph.nodes.values where n.id != gin && n.id != gout {
            let id = NodeID(); map[n.id] = id
            g.nodes[id] = NodeInstance(id: id, kind: n.kind,
                                       position: CGPoint(x: n.position.x - internalOffset.x + inst.position.x, y: n.position.y - internalOffset.y + inst.position.y),
                                       params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        // Internal wires between real nodes.
        for (to, from) in def.graph.inputs where map[to.node] != nil && map[from.node] != nil {
            g.connect(SocketRef(map[from.node]!, from.socket), to: SocketRef(map[to.node]!, to.socket))
        }
        // Inputs: whatever fed the instance's input socket now feeds every internal target of GroupInput.<name>;
        // unwired ones carry the instance's stored value (or the declared default) onto the internal input.
        for decl in def.inputs {
            let external = g.inputs[SocketRef(instance, decl.name)]
            for (to, from) in def.graph.inputs where from == SocketRef(gin, decl.name), let target = map[to.node] {
                if let ext = external { g.connect(ext, to: SocketRef(target, to.socket)) }
                else if let v = inst.params[decl.name] ?? { if case .value(let v) = decl.default { return v } else { return nil } }() {
                    g.nodes[target]!.params[to.socket] = v
                }
            }
        }
        // Outputs: whatever fed GroupOutput.<name> now feeds every external target of the instance's output.
        for decl in def.outputs {
            guard let internalSource = def.graph.inputs[SocketRef(gout, decl.name)], let src = map[internalSource.node] else { continue }
            for (to, from) in g.inputs where from == SocketRef(instance, decl.name) {
                g.connect(SocketRef(src, internalSource.socket), to: to)
            }
        }
        g.remove(nodes: [instance])
        var out = doc
        out[path] = g
        return (out, Set(map.values))
    }

    public static func makeUnique(_ instance: NodeID, in path: GraphPath, of doc: ShaderDocument) -> (document: ShaderDocument, definition: GroupID)? {
        guard let inst = doc[path].nodes[instance], case .group(let gid) = inst.kind, let def = doc.definitions[gid] else { return nil }
        var copy = GroupDefinition(name: uniqueDefinitionName(def.name + " 2", in: doc), inputs: def.inputs, outputs: def.outputs, accent: def.accent)
        var map: [NodeID: NodeID] = [:]
        for n in def.graph.nodes.values {
            let id = NodeID(); map[n.id] = id
            copy.graph.nodes[id] = NodeInstance(id: id, kind: n.kind, position: n.position, params: n.params, customTitle: n.customTitle, collapsed: n.collapsed)
        }
        for (to, from) in def.graph.inputs { copy.graph.connect(SocketRef(map[from.node]!, from.socket), to: SocketRef(map[to.node]!, to.socket)) }
        var out = doc
        out.definitions[copy.id] = copy
        out[path].nodes[instance]!.kind = .group(copy.id)
        return (out, copy.id)
    }

    public static func rename(_ id: GroupID, to name: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var out = doc; out.definitions[id]!.name = name; return out
    }

    public static func setAccent(_ id: GroupID, _ accent: DraculaAccent, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil else { return nil }
        var out = doc; out.definitions[id]!.accent = accent; return out
    }

    public static func addSocket(_ id: GroupID, kind: SocketKind, decl: SocketDecl, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id] else { return nil }
        var d = decl
        d.name = uniqueSocketName(decl.name, among: (def.inputs + def.outputs).map(\.name))
        if kind == .input { def.inputs.append(d) } else { def.outputs.append(d) }
        var out = doc; out.definitions[id] = def; return out
    }

    /// Renames everywhere (spec §20.6). Nil on an unknown socket or a clash after sanitising.
    public static func renameSocket(_ id: GroupID, kind: SocketKind, from old: String, to newName: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id] else { return nil }
        let new = StitchableCodegen.sanitizedName(newName)
        guard new != old else { return doc }
        guard !(def.inputs + def.outputs).contains(where: { $0.name == new }) else { return nil }
        let gin = def.inputNode, gout = def.outputNode
        switch kind {
        case .input:
            guard let i = def.inputs.firstIndex(where: { $0.name == old }) else { return nil }
            def.inputs[i].name = new
            def.graph.inputs = Dictionary(uniqueKeysWithValues: def.graph.inputs.map { to, from in
                (to, from == SocketRef(gin!, old) ? SocketRef(gin!, new) : from)
            })
        case .output:
            guard let i = def.outputs.firstIndex(where: { $0.name == old }) else { return nil }
            def.outputs[i].name = new
            if let f = def.graph.inputs[SocketRef(gout!, old)] { def.graph.inputs[SocketRef(gout!, old)] = nil; def.graph.inputs[SocketRef(gout!, new)] = f }
        }
        var out = doc
        out.definitions[id] = def
        // Every instance, in every graph.
        func rewrite(_ g: inout Graph) {
            for n in g.nodes.values where n.kind == .group(id) {
                switch kind {
                case .input:
                    if let f = g.inputs[SocketRef(n.id, old)] { g.inputs[SocketRef(n.id, old)] = nil; g.inputs[SocketRef(n.id, new)] = f }
                    if let v = g.nodes[n.id]!.params[old] { g.nodes[n.id]!.params[old] = nil; g.nodes[n.id]!.params[new] = v }
                case .output:
                    g.inputs = Dictionary(uniqueKeysWithValues: g.inputs.map { to, from in (to, from == SocketRef(n.id, old) ? SocketRef(n.id, new) : from) })
                }
            }
        }
        rewrite(&out.root)
        for k in out.definitions.keys { rewrite(&out.definitions[k]!.graph) }
        return out
    }

    /// Removes the socket and every wire that used it (spec §4.5, §20.6).
    public static func removeSocket(_ id: GroupID, kind: SocketKind, name: String, in doc: ShaderDocument) -> ShaderDocument? {
        guard var def = doc.definitions[id] else { return nil }
        switch kind {
        case .input:
            guard def.inputs.contains(where: { $0.name == name }) else { return nil }
            def.inputs.removeAll { $0.name == name }
            def.graph.inputs = def.graph.inputs.filter { $0.value != SocketRef(def.inputNode!, name) }
        case .output:
            guard def.outputs.contains(where: { $0.name == name }) else { return nil }
            def.outputs.removeAll { $0.name == name }
            def.graph.inputs[SocketRef(def.outputNode!, name)] = nil
        }
        var out = doc
        out.definitions[id] = def
        func prune(_ g: inout Graph) {
            for n in g.nodes.values where n.kind == .group(id) {
                switch kind {
                case .input: g.inputs[SocketRef(n.id, name)] = nil; g.nodes[n.id]!.params[name] = nil
                case .output: g.inputs = g.inputs.filter { $0.value != SocketRef(n.id, name) }
                }
            }
        }
        prune(&out.root)
        for k in out.definitions.keys { prune(&out.definitions[k]!.graph) }
        return out
    }

    public static func deleteDefinition(_ id: GroupID, in doc: ShaderDocument) -> ShaderDocument? {
        guard doc.definitions[id] != nil, !isUsed(id, in: doc) else { return nil }
        var out = doc; out.definitions[id] = nil; return out
    }

    static func zero(_ t: SocketType) -> ParamValue {
        switch t {
        case .float: .float(0); case .float2: .float2(.zero); case .float3: .float3(.zero)
        case .float4, .color: .float4(.init(0, 0, 0, 1)); case .int: .int(0); case .bool: .bool(false); case .texture: .float(0)
        }
    }
}
```

`Dictionary.filter` returns a dictionary in Swift ≥ 4 — the `g.inputs.filter { … }` lines are fine. `renameSocket`'s "2 bad" → `_2_bad` follows `sanitizedName` (leading digit prefixed, space → `_`).

- [ ] **Step 4: Run** the suite (the identity test compares generated sources — it requires T3's codegen to be deterministic for the regrouped graph, which it is because `uniqueSocketName` and the emit order are sorted).

- [ ] **Step 5: Commit** — `feat(core): group operations — cut with source dedup, ungroup, make unique, socket rename/remove/add, unique names`

---

### Task 6: Clipboard carries definitions; paste dedupes

**Files:**
- Modify: `Clipboard/GraphClipboard.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ClipboardMergeTests.swift`, `GraphClipboardTests.swift`

**Interfaces:**
- Produces: `GraphClipboard.extract(_:from:document:)` (definitions = transitively referenced, sorted by id; pseudo-nodes excluded); `ClipboardMerge.plan(definitions:into:) -> ClipboardMerge.Plan { insert: [GroupDefinition], remap: [GroupID: GroupID] }`; `ClipboardMerge.apply(_ plan:to nodes:) -> [NodeInstance]` (retargets `.group` kinds in the pasted nodes **and** inside inserted definitions' graphs).

- [ ] **Step 1: Write the failing tests**

```swift
@Suite struct ClipboardMergeTests {
    private func docWithDef() -> (ShaderDocument, GroupDefinition, NodeID) {
        var def = GroupDefinition.make(name: "Fbm")
        def.outputs = [SocketDecl(name: "v", type: .concrete(.float))]
        var doc = ShaderDocument(); doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id)); doc.root.nodes[inst.id] = inst
        return (doc, def, inst.id)
    }

    @Test func extractCarriesReferencedDefinitionsAndSkipsPseudoNodes() {
        let (doc, def, inst) = docWithDef()
        let clip = GraphClipboard.extract([inst], from: doc.root, document: doc)
        #expect(clip.definitions.map(\.id) == [def.id])
        let inner = GraphClipboard.extract(Set(def.graph.nodes.keys), from: def.graph, document: doc)
        #expect(inner.nodes.isEmpty)                                   // only pseudo-nodes were selected
    }

    @Test func sameIdSameHashReuses() {
        let (doc, def, _) = docWithDef()
        let plan = ClipboardMerge.plan(definitions: [def], into: doc)
        #expect(plan.insert.isEmpty && plan.remap.isEmpty)
    }

    @Test func sameIdDifferentHashImportsUnderAFreshId() {
        let (doc, def, _) = docWithDef()
        var changed = def; changed.name = "Fbm tweaked"
        let plan = ClipboardMerge.plan(definitions: [changed], into: doc)
        #expect(plan.insert.count == 1 && plan.insert[0].id != def.id && plan.insert[0].name == "Fbm tweaked (imported)")
        #expect(plan.remap[def.id] == plan.insert[0].id)
        let pasted = ClipboardMerge.apply(plan, to: [NodeInstance(kind: .group(def.id))])
        #expect(pasted[0].kind == .group(plan.insert[0].id))
    }

    @Test func absentDefinitionIsInsertedAsIsAndNestedReferencesAreRemapped() {
        let (doc, def, _) = docWithDef()
        var other = GroupDefinition.make(name: "Wrap")
        let nested = NodeInstance(kind: .group(def.id)); other.graph.nodes[nested.id] = nested
        var changed = def; changed.name = "Fbm 2"
        let plan = ClipboardMerge.plan(definitions: [changed, other], into: doc)
        #expect(plan.insert.count == 2)
        let wrap = plan.insert.first { $0.name == "Wrap" }!
        #expect(wrap.graph.nodes[nested.id]?.kind == .group(plan.remap[def.id]!))   // the import's id, not the original
    }
}
```

`GraphClipboardTests`: the existing `extract` call sites pass `document:` (a root-only document).

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

```swift
public extension GraphClipboard {
    static func extract(_ ids: Set<NodeID>, from graph: Graph, document doc: ShaderDocument) -> GraphClipboard {
        let real = ids.filter { graph.nodes[$0].map { $0.kind != .groupInput && $0.kind != .groupOutput } ?? false }
        var clip = extract(real, from: graph)          // the M2 implementation, unchanged
        var refs = Set<GroupID>()
        for id in real { if case .group(let g)? = graph.nodes[id]?.kind { refs.insert(g); refs.formUnion(GroupDependencies.transitive(g, in: doc)) } }
        clip.definitions = refs.compactMap { doc.definitions[$0] }.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        return clip
    }
}

/// Spec §6 / §20.7: what to do with the definitions a payload brings.
public enum ClipboardMerge {
    public struct Plan: Sendable {
        public var insert: [GroupDefinition] = []
        public var remap: [GroupID: GroupID] = [:]
    }

    public static func plan(definitions: [GroupDefinition], into doc: ShaderDocument) -> Plan {
        var plan = Plan()
        for d in definitions {
            if let existing = doc.definitions[d.id] {
                if existing.contentHash == d.contentHash { continue }
                var copy = d
                copy = GroupDefinition(id: GroupID(), name: d.name + " (imported)", inputs: d.inputs, outputs: d.outputs, graph: d.graph, accent: d.accent)
                plan.remap[d.id] = copy.id
                plan.insert.append(copy)
            } else {
                plan.insert.append(d)
            }
        }
        // Instances inside inserted definitions must follow the remap too.
        plan.insert = plan.insert.map { d in
            var m = d
            for (id, n) in m.graph.nodes { if case .group(let g) = n.kind, let r = plan.remap[g] { m.graph.nodes[id]!.kind = .group(r) } }
            return m
        }
        return plan
    }

    public static func apply(_ plan: Plan, to nodes: [NodeInstance]) -> [NodeInstance] {
        nodes.map { n in
            var m = n
            if case .group(let g) = n.kind, let r = plan.remap[g] { m.kind = .group(r) }
            return m
        }
    }
}
```

Note: a remapped inner definition's graph keeps its node ids (they are unique because the definition was absent); a definition that already exists with the same hash is reused and its inner ids are not duplicated because it is not inserted.

- [ ] **Step 4: Run** the suite.

- [ ] **Step 5: Commit** — `feat(core): clipboard carries referenced definitions; paste dedupes by content hash`

---

### Task 7: Editor model — active graph, group changes, dive in/out

**Files:**
- Modify: `Editor/EditorModel.swift`, `EditorModel+Selection.swift`, `EditorModel+Clipboard.swift`, `EditorModel+Placement.swift`, `EditorModel+Viewer.swift`, `DocumentChange.swift`
- Create: `Editor/EditorModel+Groups.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorGroupsTests.swift`, `EditorClipboardTests.swift`, `EditorViewerTests.swift`

**Interfaces:**
- Produces: `EditorModel.activePath: GraphPath`, `graph: Graph` (the active graph), `shape(of:) -> NodeShape?`, `shape(of id:)`; `DocumentChange` cases `.groupSelection(Set<NodeID>, name: String?)`, `.ungroup(NodeID)`, `.makeUnique(NodeID)`, `.renameDefinition(GroupID, String)`, `.setDefinitionAccent(GroupID, DraculaAccent)`, `.addSocket(GroupID, SocketKind, SocketDecl)`, `.renameSocket(GroupID, SocketKind, from: String, to: String)`, `.removeSocket(GroupID, SocketKind, String)`, `.deleteDefinition(GroupID)`, `.insert(nodes:edges:definitions:)`; all changes apply to `activePath`; `groupSelection() -> GroupID?`, `ungroupSelection()`, `makeUniqueSelection()`; `diveIn(_:)`, `popToLevel(_:)`, `exitGroup()`, `editDefinition(_:)`, `breadcrumb: [(title: String, level: Int)]`; `addInstance(of:at:) -> NodeID?` with recursion refusal + `notice: String?` (auto-cleared after 3 s); `canvasRequest.placeGroup(GroupID)`; `pruneViewer` clears when a path instance is gone; `compileNow` passes `viewerPath`/`viewerDefinition`; `firstOutput`, `socketLabel`, `node(at:)`, `selectAll`, `frame(of:)`, bounds and paste operate on the active graph.

- [ ] **Step 1: Write the failing tests** (`EditorGroupsTests.swift`; add the `RecordingCompiler` helper import as in `EditorModelTests`)

```swift
@MainActor
@Suite struct EditorGroupsTests {
    private func model() -> EditorModel {
        let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
        m.debounceInterval = .milliseconds(5)
        return m
    }
    private func node(_ m: EditorModel, _ defID: String, op: String? = nil) -> NodeID {
        m.document.root.nodes.values.first { $0.kind == .builtin(defID) && (op == nil || $0.params["op"] == .enumCase(op!)) }!.id
    }

    @Test func groupSelectionIsOneUndoStepAndSelectsTheInstance() async {
        let m = model()
        m.start(); await m.awaitIdle()
        let mul = node(m, "math.math", op: "multiply"), sine = node(m, "math.math", op: "sine")
        m.select(nodes: [mul, sine], mode: .replace)
        let gid = m.groupSelection()
        #expect(gid != nil && m.document.definitions.count == 1)
        #expect(m.selection.count == 1)
        let inst = m.selection.first!
        #expect(m.document.root.nodes[inst]?.kind == .group(gid!))
        #expect(m.undoManager.undoActionName == "Group")
        m.undo()
        #expect(m.document.definitions.isEmpty && m.document.root.nodes[mul] != nil)
    }

    @Test func diveInBindsChangesToTheDefinitionGraph() async {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        #expect(m.activePath == .definition(gid) && m.selection.isEmpty && m.viewState.editingStack == [inst])
        #expect(m.breadcrumb.map(\.title) == ["Shader", "Group"])
        let added = m.addNode(defID: "input.float", at: .zero)!
        #expect(m.document.definitions[gid]!.graph.nodes[added] != nil && m.document.root.nodes[added] == nil)
        m.exitGroup()
        #expect(m.activePath == .root && m.viewState.editingStack.isEmpty)
        m.editDefinition(gid)
        #expect(m.activePath == .definition(gid) && m.viewState.editingDefinition == gid)
        m.popToLevel(0)
        #expect(m.activePath == .root && m.viewState.editingDefinition == nil)
    }

    @Test func pseudoNodesCannotBeDeletedOrCopied() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        let gin = m.document.definitions[gid]!.inputNode!
        m.select(gin)
        m.deleteSelection()
        #expect(m.document.definitions[gid]!.graph.nodes[gin] != nil)
        #expect(m.clipboardData() == nil)
    }

    @Test func ungroupAndMakeUniqueGoThroughApply() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.makeUniqueSelection()
        #expect(m.document.definitions.count == 2 && m.document.root.nodes[inst]?.kind != .group(gid))
        m.ungroupSelection()
        #expect(m.document.root.nodes[inst] == nil && m.selection.count == 2)
        #expect(m.undoManager.undoActionName == "Ungroup")
    }

    @Test func recursionIsRefusedWithANotice() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.diveIn(m.selection.first!)
        #expect(m.addInstance(of: gid, at: .zero) == nil)
        #expect(m.notice == "Group cannot contain itself")
        #expect(m.document.definitions[gid]!.graph.nodes.values.contains { $0.kind == .group(gid) } == false)
    }

    @Test func socketEditsPropagateAndAreOneUndoStep() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.apply(.renameSocket(gid, .input, from: "time", to: "t"))
        #expect(m.document.root.inputs[SocketRef(inst, "t")] != nil)
        m.apply(.removeSocket(gid, .input, "t"))
        #expect(m.document.root.inputs[SocketRef(inst, "t")] == nil)
        m.undo()
        #expect(m.document.root.inputs[SocketRef(inst, "t")] != nil)
    }

    @Test func viewerInsideADefinitionCompilesThroughTheStack() async {
        let m = model()
        m.start(); await m.awaitIdle()
        m.select(nodes: [node(m, "math.math", op: "multiply"), node(m, "math.math", op: "sine")], mode: .replace)
        let gid = m.groupSelection()!
        let inst = m.selection.first!
        m.diveIn(inst)
        let sine = m.document.definitions[gid]!.graph.nodes.values.first { $0.params["op"] == .enumCase("sine") }!.id
        m.setViewer(SocketRef(sine, "out")); await m.awaitIdle()
        #expect(m.generatedSource.contains("_view(") && m.generatedSource.contains("u.viewerMin"))
        m.exitGroup()
        m.apply(.removeNodes([inst])); await m.awaitIdle()
        #expect(m.viewer == nil)
    }

    @Test func pasteBringsDefinitionsAlong() {
        let m = model()
        m.select(nodes: [node(m, "math.math", op: "multiply")], mode: .replace)
        let gid = m.groupSelection()!
        m.copySelection()
        var d = m.document
        d.definitions[gid] = nil                                   // simulate a document that lacks it
        d.root.nodes[m.selection.first!] = nil
        m.apply(.restore(d))
        m.paste(at: .zero)
        #expect(m.document.definitions[gid] != nil)
    }
}
```

`EditorClipboardTests`: `extract` calls take `document:`. `EditorViewerTests`: unchanged expectations.

- [ ] **Step 2: Run to see them fail.**

- [ ] **Step 3: Implement**

`DocumentChange`: add the cases above; `.insert` gains `definitions: [GroupDefinition]` (default `[]` via a static helper or update the two call sites); `changeClass`: all new cases `.topology` except `.renameDefinition`/`.setDefinitionAccent` (`.cosmetic`); `undoName`: "Group", "Ungroup", "Make Unique", "Rename Group", "Change Group Color", "Add Socket", "Rename Socket", "Remove Socket", "Delete Group".

`EditorModel`:
```swift
    public var activePath: GraphPath { viewState.activePath(in: document) }
    public var graph: Graph { document[activePath] }
    public func shape(of node: NodeInstance) -> NodeShape? { document.shape(of: node, in: activePath, registry: registry) }
    public func shape(of id: NodeID) -> NodeShape? { document.shape(of: id, registry: registry) }
    /// A transient message for the preview pane (recursion refusal); cleared after 3 s.
    public var notice: String?
```
`perform`: every `document.root.…` becomes `document[activePath].…` (`moveNodes`, `setParam`, `setTitle`, `connect`, `disconnect`, `addNode`, `removeNodes` — refuse pseudo-nodes: `ids.filter { shape(of: $0)?.isPseudo != true }`, `insert`). New cases:
```swift
        case .groupSelection(let ids, let name):
            if let r = GroupOperations.group(ids, in: activePath, of: document, registry: registry, resolved: resolvedTypes, name: name) {
                document = r.document; viewState.selection = [r.instance]
            }
        case .ungroup(let id):
            if let r = GroupOperations.ungroup(id, in: activePath, of: document) { document = r.document; viewState.selection = r.nodes }
        case .makeUnique(let id):
            if let r = GroupOperations.makeUnique(id, in: activePath, of: document) { document = r.document }
        case .renameDefinition(let id, let n): document = GroupOperations.rename(id, to: n, in: document) ?? document
        case .setDefinitionAccent(let id, let a): document = GroupOperations.setAccent(id, a, in: document) ?? document
        case .addSocket(let id, let k, let d): document = GroupOperations.addSocket(id, kind: k, decl: d, in: document) ?? document
        case .renameSocket(let id, let k, let old, let new): document = GroupOperations.renameSocket(id, kind: k, from: old, to: new, in: document) ?? document
        case .removeSocket(let id, let k, let n): document = GroupOperations.removeSocket(id, kind: k, name: n, in: document) ?? document
        case .deleteDefinition(let id): document = GroupOperations.deleteDefinition(id, in: document) ?? document
        case .insert(let nodes, let edges, let defs):
            let plan = ClipboardMerge.plan(definitions: defs, into: document)
            for d in plan.insert { document.definitions[d.id] = d }
            for n in ClipboardMerge.apply(plan, to: nodes) { document[activePath].nodes[n.id] = n }
            for e in edges { document[activePath].connect(e.from, to: e.to) }
```
After `.removeNodes`/`.restore`/`.ungroup`/`.deleteDefinition`: `pruneSelection()`, `pruneViewer()`, and `pruneEditingStack()` (drop the stack from the first missing instance; clear `editingDefinition` if its definition is gone).

`EditorModel+Groups.swift`:
```swift
extension EditorModel {
    @discardableResult public func groupSelection(name: String? = nil) -> GroupID? {
        let ids = selection.filter { shape(of: $0)?.isPseudo != true }
        guard !ids.isEmpty else { return nil }
        let before = Set(document.definitions.keys)
        apply(.groupSelection(ids, name: name))
        return Set(document.definitions.keys).subtracting(before).first
    }
    public func ungroupSelection() { guard selection.count == 1, let id = selection.first, case .group? = graph.nodes[id]?.kind else { return }; apply(.ungroup(id)) }
    public func makeUniqueSelection() { guard selection.count == 1, let id = selection.first, case .group? = graph.nodes[id]?.kind else { return }; apply(.makeUnique(id)) }

    public func diveIn(_ instance: NodeID) {
        guard case .group? = graph.nodes[instance]?.kind else { return }
        viewState.editingStack.append(instance); viewState.editingDefinition = nil
        clearSelection()
    }
    public func exitGroup() { popToLevel(max(0, viewState.editingStack.count - 1)) }
    /// Level 0 is the root; level n keeps the first n stack entries.
    public func popToLevel(_ level: Int) {
        if level == 0 { viewState.editingStack = []; viewState.editingDefinition = nil } else { viewState.editingStack = Array(viewState.editingStack.prefix(level)) }
        clearSelection()
    }
    public func editDefinition(_ id: GroupID) {
        guard document.definitions[id] != nil else { return }
        viewState.editingStack = []; viewState.editingDefinition = id
        clearSelection()
    }
    public var breadcrumb: [(title: String, level: Int)] {
        var out = [(title: "Shader", level: 0)]
        for (i, inst) in viewState.editingStack.enumerated() {
            if let (n, _) = document.node(inst), case .group(let g) = n.kind { out.append((n.customTitle ?? document.definitions[g]?.name ?? "Group", i + 1)) }
        }
        if let d = viewState.editingDefinition, viewState.editingStack.isEmpty, let def = document.definitions[d] { out.append((def.name, 1)) }
        return out
    }

    /// Places an instance; refused (with a notice) when it would create recursion (spec §4.6).
    @discardableResult public func addInstance(of id: GroupID, at point: CGPoint) -> NodeID? {
        guard let def = document.definitions[id] else { return nil }
        if GroupDependencies.wouldRecurse(placing: id, in: activePath, document: document) {
            showNotice("\(def.name) cannot contain itself"); return nil
        }
        let n = NodeInstance(kind: .group(id), position: point)
        apply(.addNode(n)); select(n.id)
        return n.id
    }

    func showNotice(_ text: String) {
        notice = text
        Task { try? await Task.sleep(for: .seconds(3)); if notice == text { notice = nil } }
    }

    func pruneEditingStack() {
        if let i = viewState.editingStack.firstIndex(where: { id in guard let (n, _) = document.node(id), case .group = n.kind else { return true }; return false }) {
            viewState.editingStack = Array(viewState.editingStack.prefix(i))
        }
        if let d = viewState.editingDefinition, document.definitions[d] == nil { viewState.editingDefinition = nil }
    }
}
```
`CanvasRequest` gains `.placeGroup(GroupID)`. `addNode(defID:)` unchanged (builtins). `clipboardData` uses `GraphClipboard.extract(selection, from: graph, document: document)` and returns nil when nothing real is selected. `paste`/`duplicateSelection` insert with `clip.definitions`. `deleteSelection` filters pseudo-nodes. `pruneViewer`: valid document-wide **and** every `viewerPath` id still resolves (else clear). `compileNow`: `generateResult(doc, target:, viewer:, viewerPath: viewState.editingStack, viewerDefinition: viewState.editingDefinition, registry:)` — but only when the viewer's node is *inside* a definition; if the viewer is in the root, pass `[]`/`nil` (so viewing a root node while dived in still works). `firstOutput(of:)`/`socketLabel`/`node(at:)`/`selectAll`/`frame`/`bounds`/`connectIfCompatible` use `graph` + shapes (T8 changes `NodeGeometry`/`DropResolver` to take a shape provider `(NodeInstance) -> NodeShape?`; until then use the registry-based signatures and switch in T8 — do T7 and T8 as one dispatch if that ordering is awkward).

- [ ] **Step 4: Run** the suite; fix `EditorClipboardTests` call sites.

- [ ] **Step 5: Commit** — `feat(ui): active graph path, group DocumentChanges, dive in/out, recursion notice, definitions on paste`

---

### Task 8: Canvas over shapes — group instances, pseudo-nodes, dive-in by double-click

**Files:**
- Modify: `Canvas/NodeGeometry.swift`, `Canvas/DropResolver.swift`, `Canvas/NodeView.swift`, `Canvas/GraphCanvasView.swift`, `Canvas/WireLayer.swift`, `Theme/DraculaTheme.swift`
- Test: `NodeGeometryTests.swift`, `DropResolverTests.swift`, `DraculaThemeTests.swift`

**Interfaces:**
- Produces: `NodeGeometry` and `DropResolver` functions take `shapes: (NodeInstance) -> NodeShape?` instead of `registry:` (keep `registry:` overloads that build the closure from a root-only document for existing tests); `NodeView` takes `shape: NodeShape` (not `def`), `onOpen: () -> Void` (double-click on a group header dives), draws the doubled border for `category == .group && !isPseudo`, header colour = `accent` token or the category token, no ◉ badge and no params on pseudo-nodes; `DraculaTheme.token(for: .group) == .purple`; canvas iterates `model.graph` with `model.shape(of:)`.

- [ ] **Step 1: Tests** — `NodeGeometryTests`: an instance's frame height = `26 + 16 + rows × 22` with rows = inputs + outputs of the definition; a pseudo `GroupInput` frame counts its outputs; `socketAnchor` for `SocketRef(instance, "x")`. `DropResolverTests`: `firstCompatibleInput(on: instance…)` finds an exposed input; `inputType(of: SocketRef(groupOutputNode, "out"))` = the declared type. `DraculaThemeTests`: `.group` → `.purple`.

- [ ] **Step 2: Implement**
- `NodeGeometry`: `bodyRows(_ s: NodeShape)`, `estimatedSize(for: NodeShape)`, `frame(for:shape:)`, `frame(for:shapes:)`, `socketAnchor(for:in:shapes:)`, `nodes(in:intersecting:shapes:)`, `bounds(of:in:shapes:)`, `visibleNodes(in:transform:viewport:shapes:margin:keeping:onTop:)`. Keep the old `registry:` entry points as wrappers: `shapes = { n in var d = ShaderDocument(); d.root = graph; return d.shape(of: n, in: .root, registry: registry) }`.
- `DropResolver`: `shape(of:)` replaces `def(of:)`; all functions take `shapes:`.
- `WireLayer`: takes `shapes:`.
- `NodeView`: `let shape: NodeShape`; header background `shape.accent.map { DraculaTheme.token(for: $0).color } ?? DraculaTheme.token(for: shape.category).color`; group instance overlay: `RoundedRectangle(cornerRadius: 8).stroke(accent, lineWidth: 2)` plus `.padding(3)` inner `stroke(accent, lineWidth: 1)` when `shape.category == .group && !shape.isPseudo`; params only for `!shape.isPseudo` (a shape's `params` is empty for groups anyway); badge only when `!shape.outputs.isEmpty && !shape.isPseudo`; header gains `.highPriorityGesture(TapGesture(count: 2).onEnded { onOpen() })` — no: the existing header `DragGesture(minimumDistance: 0)` swallows taps (M2 T11 lesson) — instead synthesise the double-click in `headerDrag.onEnded` exactly like `GraphCanvasView.backgroundDrag` does (`lastHeaderClick` state, ≤ 400 ms, ≤ 4 pt) and call `onOpen()`; `onOpen` is a no-op for non-groups.
- `GraphCanvasView`: `model.graph` everywhere `model.document.root` was; `let shapes: (NodeInstance) -> NodeShape? = { model.shape(of: $0) }` passed to geometry/resolver/wire layer; `NodeView(node:shape:…)` for every node with a shape (builtin, group, pseudo); `onOpen: { model.diveIn(node.id) }`; `socketUnderPress` uses shapes; `place(_ def:)` unchanged for builtins; camera keyed by `model.activePath` (`model.viewState.cameras[model.activePath]`), restored `.onChange(of: model.activePath)`; `dropDestination` also accepts `NodeDefTransfer` with `groupID` (T9) → `model.addInstance(of:at:)`.
- `InspectorView.nodePane` temporarily handles `.group` by showing the title/exposed inputs via `model.shape(of:)` (T9 replaces it with the full panes) — at minimum it must not show "Unknown node" for instances.

- [ ] **Step 3: Build, test, run the app**: ⌘G not wired yet (T9) — verify by constructing `ShaderDocument.sampleWithGroup()` as the app's initial document temporarily? No: keep `.sample()`; verify instance rendering in T9's hand check instead. Gate here: suite green, app builds.

- [ ] **Step 4: Commit** — `feat(ui): canvas, geometry and wiring over NodeShape — group instances, pseudo-nodes, double-click dives in`

---

### Task 9: Commands, breadcrumb, inspector panes, palette "My Functions"

**Files:**
- Create: `Editor/BreadcrumbBar.swift`, `Editor/InspectorView+Groups.swift`
- Modify: `Editor/EditorView.swift`, `Editor/EditorCommands.swift`, `Editor/InspectorView.swift`, `Palette/PaletteView.swift`, `Palette/PaletteSearch.swift`, `Palette/NodeDefTransfer.swift`, `Canvas/GraphCanvasView.swift` (drop + `.placeGroup`)
- Test: `PaletteSearchTests.swift` (category order incl. `.group`), `EditorGroupsTests.swift` (breadcrumb already)

- [ ] **Step 1: Implement**
- `EditorCommands` (Edit menu, after Duplicate): "Group" ⌘G (`disabled` unless `canvasHasFocus` and the selection has ≥ 1 non-pseudo node), "Ungroup" ⌘⇧G (one selected instance), "Make Unique" (one selected instance), "Edit Group" ⌘↓ (one selected instance → `diveIn`), "Exit Group" ⌘↑ (stack non-empty or editing a definition → `exitGroup`).
- `BreadcrumbBar(model:)`: `HStack` of `Button(title) { model.popToLevel(level) }` separated by `›`, last bold, 24 pt tall, background `DraculaToken.surface`; placed above the canvas in `EditorView.split` (`VStack(spacing: 0) { BreadcrumbBar; GraphCanvasView }`).
- `EditorView.previewPane`: below the viewer strip, `if let n = model.notice { Text(n).font(.caption).foregroundStyle(DraculaTheme.error.color) }`.
- `InspectorView`: `nodePane` for `.group` instances → `InstancePane(model:id:)` in `InspectorView+Groups.swift`: title field (`setTitle`), definition name (read-only, with "Edit Group" → `diveIn`, "Make Unique", "Ungroup" buttons), exposed inputs (wired → "← source", unwired → `ParamControl` bound to `instance.params[socket]` via `.setParam(id, socket, value)`), outputs with ◉. For pseudo-nodes → `DefinitionPane` (below). When nothing is selected and `activePath` is a definition → `DefinitionPane(model:id:)`: name `TextField` (`renameDefinition` on submit), accent `Picker` over `DraculaAccent.allCases` (`setDefinitionAccent`), "Inputs"/"Outputs" lists: each row a `TextField` (rename on submit → `.renameSocket`) + type label + "−" button (`.removeSocket`), "Delete definition" (enabled when `!GroupOperations.isUsed`). Document settings stay for the root.
- Palette: `PaletteSearch.grouped` unchanged for builtins; "My Functions" section lists `model.document.definitions.values.sorted(by: name)` rows: accent dot, name, "Edit" button (`editDefinition`), `.draggable(NodeDefTransfer(groupID:))`, double-click → `model.requestCanvas(.placeGroup(id))`; search filters definitions by name too (`PaletteSearch.filterDefinitions(_:in:)`). `NodeDefTransfer` gains `var groupID: GroupID?` (Codable; `defID` becomes optional or an enum — keep `defID: String?` + `groupID: GroupID?`). Canvas `dropDestination`: `groupID` → `model.addInstance(of:at:)`; `.placeGroup` request → `addInstance` at the viewport centre.
- `PaletteSearchTests` category order expectation gains `.group` before `.output` only where definitions exist (builtins never have `.group`) — adjust the assertion that enumerates `NodeCategory.allCases` if any.

- [ ] **Step 2: Build, test, hand check** (launch the app): select Multiply + Sine, ⌘G → a purple "Group" node with `time`/`out` inputs and `out` output, preview unchanged (gen +1); double-click → breadcrumb "Shader › Group", pseudo-nodes visible; ⌘↑ back; inspector shows the instance pane; Make Unique → "Group 2"; ⌘⇧G restores; palette lists "Group" under My Functions; drag it in → second instance renders; drop it inside its own definition → notice "Group cannot contain itself".

- [ ] **Step 3: Commit** — `feat(ui): ⌘G/⌘⇧G/Make Unique/Edit/Exit Group, breadcrumb, instance and definition inspector panes, My Functions palette`

---

### Task 10: Exposing sockets by wiring; viewer inside definitions in the UI

**Files:**
- Modify: `Canvas/NodeView.swift`, `Canvas/GraphCanvasView.swift`, `Canvas/DropResolver.swift`, `Editor/EditorView.swift`, `Editor/EditorModel+Viewer.swift`
- Test: `DropResolverTests.swift` (`+` handling), `EditorGroupsTests.swift` (`exposeInput/exposeOutput` model helpers)

- [ ] **Step 1: Implement**
- Model helpers: `exposeOutput(from source: SocketRef, in definition: GroupID) -> String` (adds an output named after `source.socket`, typed from the resolved/declared type, connects `source → GroupOutput.<name>`; one transaction "Expose Output"); `exposeInput(to target: SocketRef, in definition:) -> String` (adds an input named after `target.socket` typed from the target's input type, default `.value(zero)`, connects `GroupInput.<name> → target`; "Expose Input").
- Shapes: `ShaderDocument.shape` gives pseudo-nodes a trailing synthetic socket named `+` (input on `GroupOutput`, output on `GroupInput`) with `type: .concrete(.float)` and `default: .required` — `NodeShape.plusSocket` marks it so `NodeGeometry` counts it as a row, `NodeView` draws it as a `+` glyph instead of a label, validation ignores it (`GraphValidator` skips sockets named `+`; `Emitter`/`TypeResolver` never see a wire on it because dropping on it is intercepted).
- `DropResolver.compatible` treats a `+` target as compatible with any non-texture type; `PendingWire` gains `isWildcard` for a drag *from* `GroupInput.+` (dims nothing, compatible with any input).
- `GraphCanvasView.endWire`: `.socket(let input)` where `input.socket == "+"` and the node is a `GroupOutput` → `model.exposeOutput(from: w.source, in: gid)`; a wildcard drag dropped on an input socket → `model.exposeInput(to: input, in: gid)`; on a node body → its first input; on empty canvas → cancel (no chooser for wildcards).
- Viewer UI: `EditorView`'s "Viewing …" label uses `model.socketLabel` (document-wide); `EditorModel+Viewer.firstOutput` uses shapes; the badge is hidden on pseudo-nodes (T8) and shown on instances (viewing an instance's output = its normal output in the *enclosing* graph, which needs no view variant).

- [ ] **Step 2: Hand check**: inside a definition, drag Value Noise.Value onto the Group Output's `+` → a new output `Value` appears on the instance outside; drag from Group Input's `+` onto Math.B → input `b` appears; rename it in the inspector → the instance's socket renames; remove it → wire gone, one ⌘Z brings both back; ◉ on the internal Sine node → preview shows the sine through the instance's time input.

- [ ] **Step 3: Commit** — `feat(ui): expose sockets by wiring into +, wildcard drags from Group Input, viewer badges inside definitions`

---

### Task 11: Integration — build, suite, greps, manual checklist

- [ ] **Step 1**: `swift build` warning-free; `swift test` green (≈ Core 175 / Render 25 / UI 105); GPU `ShaderCompilerTests`; `xcodebuild … build`; `git checkout -- MetalNodes.xcodeproj/project.pbxproj; rm -rf MetalNodes.xcodeproj/xcshareddata`.
- [ ] **Step 2: Greps**: hex outside DraculaTheme (empty); Core imports (Foundation/CoreGraphics only); `document.root` in `MetalNodesUI` (only inside `EditorModel` where the root is meant — list and justify each hit); AppKit gating.
- [ ] **Step 3: Manual checklist** (record observed/failed; fixes committed as `fix(…): … — manual check N`):
  1. ⌘G on Multiply+Sine: instance with `time`, `out` inputs and `out` output; preview identical; gen +1; Edit ▸ Undo reads "Undo Group"; ⌘Z restores; ⇧⌘Z regroups.
  2. Double-click the instance → breadcrumb "Shader › Group"; canvas shows Group Input (right edge sockets `time`, `out`, `+`), Multiply, Sine, Group Output (`out`, `+`); selection empty; camera independent from the root's.
  3. Move Sine inside; ⌘↑; the instance's preview unchanged; dive again: Sine where you left it.
  4. Change Sine's Operation to Cosine inside → preview updates (gen +1) — shared behaviour: add a second instance from the palette, both change.
  5. Unwired exposed input: delete the wire into the instance's `out` input; the instance shows a slider; scrubbing it changes only that instance (per-instance slot, no recompile).
  6. Expose: inside, drag Multiply.Out onto Group Output `+` → new output `out2`... (name follows the source socket: `out` exists → `out2`); outside, the instance has a second output; wire it to Combine.z.
  7. Expose input: drag Group Input `+` onto Sine.B → input `b`; outside, the instance gains `b` with a slider.
  8. Rename `b` → `phase` in the definition pane: the instance's socket reads `phase`, wires intact; remove `time`: the wire into the instance disappears; one ⌘Z brings socket + wire back.
  9. Make Unique on the second instance → "Group 2" in the palette; editing "Group 2" (change Cosine back to Sine) affects only that instance.
  10. Ungroup the first instance → Multiply/Sine back in the root, wires intact, preview identical; "Group" stays under My Functions; the definition pane offers "Delete definition" once unused.
  11. Recursion: inside "Group", drag "Group" from the palette → notice "Group cannot contain itself"; nested: put "Group 2" inside "Group" (allowed), then try "Group" inside "Group 2" → refused.
  12. Nested codegen: with Group 2 inside Group, the preview renders and the export (Color Effect) contains both functions inner-first.
  13. Viewer inside: dive into Group, ◉ on Sine → preview shows the sine through the dived instance; ⌘↑ keeps the viewer; delete the instance → viewer cleared.
  14. Palette Edit: My Functions ▸ Edit on "Group" (no instance) → breadcrumb "Shader › Group"; ◉ on Multiply → preview uses declared defaults (flat colour); exit.
  15. Copy the instance, ⌘V → second instance sharing the definition; paste into the definition of "Group 2" → allowed (no recursion); paste "Group 2"'s instance into "Group 2" → refused.
  16. Cut a pseudo-node / ⌫ on it → nothing happens; ⌘G with a pseudo-node selected → disabled.
  17. Stitchable target with a grouped graph: preview renders for all three kinds; Export writes both files; snippet argument names include the instance's unwired input (`groupPhase`…).
  18. Undo across a socket rename after paste → consistent (no stray refs; validation "No problems").

## Done criteria for this plan

- Group / dive / make unique / ungroup / expose / rename / remove all work from the canvas, the menu and the inspector, each one undo step; nested groups and recursion refusal; definitions in the palette; definitions travel with paste and dedupe; viewer inside definitions.
- Every group program compiles on the device under all four targets; goldens for one-level, nested, shared vs per-instance slots, viewer variants.
- Suite green, warning-free, greps clean, 18 manual checks observed.

## What the next plan (M5) starts from

Package persistence (`DocumentGroup`, `document.json` + `view.json` + `textures/`), Texture Sample + `layer.sample`, comment frames and stickies (already on `Graph`), the generated-code panel (uses `LineMap` — extend `SourceBuilder` owners into group function bodies), minimap, `.metal` export of the fragment program, cross-document paste (the dedupe logic is in place). Deferred from M4: line owners inside group functions (compile errors inside a definition currently map to no node), socket reordering, per-instance slots for nested instances (spec §9.2 says shared; revisit only if users ask), viewer numeric readout.
