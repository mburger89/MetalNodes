# MetalNodes M11 — Review Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix every confirmed, user-reachable bug and every hot-path performance defect the 2026-09-09 four-reviewer pass found, with a regression test per fix, without moving the document format or any corpus golden.

**Architecture:** No new subsystems. Core gains tolerant decoders, a bounded `Timeline`, a wider and rule-based Expression scanner, and O(N+E) graph traversals. Render gains a video size ceiling checked before the first frame, exact video duration, memoryless depth, a draw rate that follows a fixed-rate timeline, and consistent colour tagging. The editor records only the document's compiled program, reports early failures inside the sheet it already owns, dies with its window, and syncs the clock only when the clock moved. The canvas stops writing observable state per wheel tick and per mouse move, keeps its shape cache across drags, and stops guessing about transaction ownership.

**Tech Stack:** Swift 6.4 strict concurrency, SwiftUI + AppKit/UIKit, Metal/MetalKit, AVFoundation, Swift Testing; Xcode 26.6 for `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` §27 (M11 addendum). §27 wins wherever it and §24/§25/§26 differ. The review reports the plan argues from are `docs/superpowers/reviews/2026-09-09-ultrareview-{core,render,editor,canvas}.md`; a task brief names the finding it closes so the implementer can read the reviewer's full scenario.

## Global Constraints

- **The document format stays at version 2.** Every decoder change is tolerance or refusal of input no build has written; `FormatCorpusTests` passes untouched. Generated MSL for every corpus document is byte-identical before and after.
- **Every fix has a mutation check** recorded in the report: revert the production change once, confirm the new test fails, restore. A test that passes against the pre-fix code is not done.
- **No API is called without checking it exists** in the platform SDK for both macOS 26 and iOS 26 (grep the `.swiftinterface` when unsure). Reporting a gap is the correct response, never fabricating a call.
- **Never commit `MetalNodes.xcodeproj/project.pbxproj`.** After every `xcodebuild`: `git checkout -- MetalNodes.xcodeproj/project.pbxproj`. `xcodebuild` runs as `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`. Never use bare `git stash`.
- **Warning-free:** `swift build` prints zero `warning:` lines; `xcodebuild` for `platform=macOS` and `generic/platform=iOS` print zero.
- **GPU tests skip, not fail, without a device** (`MTLCreateSystemDefaultDevice() == nil`), using the `withKnownIssue("no Metal device")` pattern `PreviewDrawTests` uses.
- **Test commands:** `cd MetalNodesKit && swift test --filter <SuiteName>` for one suite; `swift test` for the package. The package tests run with the local toolchain; `xcodebuild` is for the app targets.
- **Commit trailers:**
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```

## File Structure

| File | Responsibility in M11 |
|---|---|
| `MetalNodesKit/Sources/MetalNodesCore/Persistence/DecodingSupport.swift` | **New.** `Dictionary.uniqueOrThrow` — the one place a repeated key becomes a `DecodingError`. |
| `MetalNodesCore/Graph.swift`, `ShaderDocument.swift`, `Persistence/ShaderPackage.swift` | Tolerant decoders; `node(_:)` without the sort; the corrupt-data message. |
| `MetalNodesCore/Codegen/TypeResolver.swift`, `Codegen/Validation.swift` | Uniquing socket maps; the duplicate-socket rule; reverse adjacency in the cycle walk. |
| `MetalNodesCore/Codegen/TopoSort.swift` | Reverse adjacency. |
| `MetalNodesCore/Timeline.swift` | Bounded arithmetic, clamped decode, end state, time-preserving retarget. |
| `MetalNodesCore/ParamValue.swift`, `ParamValues.swift` | `finite`; literal spellings. |
| `MetalNodesCore/Codegen/MSLScanner.swift`, `Library/Builtin/ExpressionNode.swift` | Reserved names, call rule, numbers, ASCII identifiers, comment stripping, tokenise memo. |
| `MetalNodesRender/Recording/VideoSink.swift`, `FrameSink.swift`, `ExportSession.swift` | Size ceilings, `endSession`, status checks, colour tags, padding, memoryless depth, `encodeFailed`. |
| `MetalNodesRender/ShaderRenderer.swift`, `PreviewView.swift` | Draw rate, guarded clock writes, sRGB layer. |
| `MetalNodesUI/Editor/EditorModel+Recording.swift`, `EditorView.swift`, `RecordingSheet.swift`, `EditorCommands.swift`, `EditorViewPad.swift`, `EditorModel.swift` | The gate, the failed phase, lifetime, `isRecording`, sheet validity, Escape. |
| `MetalNodesUI/Editor/EditorModel.swift`, `EditorModel+Undo.swift`, `DocumentChange.swift`, `InspectorView.swift` | `syncClock` guard, `changesShapes`, `finite` params, `endAllTransactions`, draft fields. |
| `MetalNodesUI/Canvas/GraphCanvasView.swift`, `NodeView.swift`, `ParamControl.swift`, `NodeGeometry.swift`, `CommentLayer.swift`, `DropResolver.swift` | Wheel debounce, hover box, UUID sorts, LOD freeze, transaction ownership, Space latch. |

## Execution order (for the controller)

Serial, one worktree, Tasks 1 → 10; the tasks share files (Task 1 and 4 both edit `Timeline.swift`; 9 and 10 both edit `GraphCanvasView.swift`; 5 and 7 share `isSizeSupported`). Task 11 is the controller's.

---

### Task 1: Core decode and validation hardening

Closes core review findings 1, 4, 5, 6 and 14 (asset extension).

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Persistence/DecodingSupport.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Graph.swift:122-131` (decoder), `ShaderDocument.swift:310-316` (decoder), `Persistence/ShaderPackage.swift:64-68`, `Codegen/TypeResolver.swift:48-49`, `Codegen/Validation.swift:39-52`, `Timeline.swift:6-24`, `ParamValue.swift:31-50`, `ParamValues.swift:48-51`, and the `AssetInfo` decoder (grep `struct AssetInfo` in `MetalNodesCore`).
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GraphCodableTests.swift`, `ShaderDocumentTests.swift`, `GroupValidationTests.swift`, `TimelineTests.swift`, `ParamValueTests.swift`, `ShaderPackageTests.swift`.

**Interfaces:**
- Produces: `Dictionary.uniqueOrThrow(_:codingPath:describe:)`; `Timeline.maxDuration`, `Timeline.isValidDuration(_:)`, `Timeline.frameCount(duration:frameRate:)`; `ParamValue.finite`.
- Task 8 uses `Timeline.isValidDuration` (in `setTimeline`) and `ParamValue.finite` (in `perform`).

- [ ] **Step 1: Write the failing tests**

`GraphCodableTests.swift` (append to the existing suite):

```swift
@Test func aDuplicateNodeIdIsADecodingErrorNotATrap() throws {
    let id = NodeID()
    let n = NodeInstance(id: id, kind: .builtin("input.uv"), position: .zero)
    var g = Graph()
    g.nodes[id] = n
    var json = String(decoding: try JSONEncoder().encode(g), as: UTF8.self)
    // Duplicate the one-element nodes array by hand: `[{…}]` → `[{…},{…}]`.
    let nodes = try #require(json.range(of: "\"nodes\":["))
    let element = json[nodes.upperBound...].prefix { $0 != "]" }
    json.insert(contentsOf: "," + element, at: nodes.upperBound)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Graph.self, from: Data(json.utf8)) }
}

@Test func twoWiresIntoOneSocketAreADecodingError() throws {
    let a = NodeID(), b = NodeID(), c = NodeID()
    let json = """
    {"nodes":[],"edges":[{"to":{"node":"\(a.raw.uuidString)","socket":"x"},"from":{"node":"\(b.raw.uuidString)","socket":"out"}},
                          {"to":{"node":"\(a.raw.uuidString)","socket":"x"},"from":{"node":"\(c.raw.uuidString)","socket":"out"}}]}
    """
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(Graph.self, from: Data(json.utf8)) }
}
```
Check the `Edge`/`SocketRef` JSON key names against an encoded sample before relying on the literal above; if they differ, build the second document by encoding a one-edge graph and duplicating the element as the first test does.

`ShaderDocumentTests.swift`:

```swift
@Test func aDuplicateDefinitionIdIsADecodingError() throws {
    var doc = ShaderDocument()
    let def = GroupDefinition(name: "Twice")
    doc.definitions[def.id] = def
    var json = String(decoding: try JSONEncoder().encode(doc), as: UTF8.self)
    let defs = try #require(json.range(of: "\"definitions\":["))
    var depth = 0
    var end = defs.upperBound
    for i in json[defs.upperBound...].indices {
        if json[i] == "{" { depth += 1 }
        if json[i] == "}" { depth -= 1; if depth == 0 { end = json.index(after: i); break } }
    }
    let element = String(json[defs.upperBound..<end])
    json.insert(contentsOf: "," + element, at: defs.upperBound)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(ShaderDocument.self, from: Data(json.utf8)) }
}
```

`ShaderPackageTests.swift`:

```swift
@Test func aCorruptDocumentReportsTheReasonNotADump() throws {
    let a = NodeID()
    let json = """
    {"formatVersion":2,"settings":{},"definitions":[],"root":{"nodes":[
      {"id":"\(a.raw.uuidString)","kind":{"builtin":"input.uv"},"position":[0,0],"params":{}},
      {"id":"\(a.raw.uuidString)","kind":{"builtin":"input.uv"},"position":[0,0],"params":{}}],"edges":[]}}
    """
    let wrapper = FileWrapper(directoryWithFileWrappers: [
        ShaderPackage.documentFileName: FileWrapper(regularFileWithContents: Data(json.utf8)),
    ])
    #expect(throws: PackageError.self) { try ShaderPackage(fileWrapper: wrapper) }
    do { _ = try ShaderPackage(fileWrapper: wrapper) } catch {
        #expect(error.errorDescription?.contains("duplicate node id") == true, "\(error)")
    }
}
```
Confirm the `NodeInstance` JSON shape (`kind`, `position`, `params` spellings) from an encoded sample first; adjust the literal to match. `documentFileName` may be `internal` — the test target uses `@testable import`.

`GroupValidationTests.swift`:

```swift
@Test func duplicateSocketNamesOnADefinitionAreADiagnosticNotATrap() {
    var doc = ShaderDocument.starter()
    var def = GroupDefinition(name: "Dup",
                              inputs: [SocketDecl(name: "a", type: .concrete(.float)), SocketDecl(name: "a", type: .concrete(.float))],
                              outputs: [SocketDecl(name: "out", type: .concrete(.float))])
    let input = NodeInstance(kind: .builtin(GroupInputNode.id), position: .zero)
    let output = NodeInstance(kind: .builtin(GroupOutputNode.id), position: .zero)
    def.graph.nodes[input.id] = input
    def.graph.nodes[output.id] = output
    def.graph.inputs[SocketRef(output.id, "out")] = SocketRef(input.id, "a")
    doc.definitions[def.id] = def
    let instance = NodeInstance(kind: .group(def.id), position: .zero)
    doc.root.nodes[instance.id] = instance
    let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
    #expect(diags.contains { $0.message == "Definition “Dup” declares two inputs named “a”" })
    // Generation must refuse through the diagnostic, never trap.
    #expect(throws: GenerationError.self) {
        try ShaderGenerator.generate(doc, target: .fragment, viewer: nil, viewerPath: [], viewerDefinition: nil, registry: .builtin)
    }
}
```
Use the pseudo-node ids the existing group tests use (grep `GroupInputNode`/`"group.input"` in `GroupValidationTests.swift`) — the names above are placeholders for whatever the file already spells.

`TimelineTests.swift`:

```swift
@Test func anAbsurdDurationDecodesToTheDefaultAndNeverTraps() throws {
    for json in [#"{"duration":1e300,"frameRate":60,"loops":true}"#,
                 #"{"duration":-1,"frameRate":60,"loops":true}"#,
                 #"{"duration":0,"frameRate":60,"loops":true}"#,
                 #"{"duration":4000,"frameRate":60,"loops":true}"#] {
        let t = try JSONDecoder().decode(Timeline.self, from: Data(json.utf8))
        #expect(t.duration == 4, json)
        #expect(t.frameCount == 240, json)
    }
    let zero = try JSONDecoder().decode(Timeline.self, from: Data(#"{"duration":2,"frameRate":0,"loops":false}"#.utf8))
    #expect(zero.frameRate == 60)
    #expect(zero.duration == 2)
    let missing = try JSONDecoder().decode(Timeline.self, from: Data("{}".utf8))
    #expect(missing == Timeline())
}

@Test func frameCountIsBoundedBeforeTheIntConversion() {
    #expect(Timeline.frameCount(duration: 1e300, frameRate: 60) == 1_000_000_000)
    #expect(Timeline.frameCount(duration: .nan, frameRate: 60) == 1)
    #expect(Timeline.frameCount(duration: 0.001, frameRate: 24) == 1)
    #expect(Timeline.isValidDuration(3600))
    #expect(!Timeline.isValidDuration(3600.5))
    #expect(!Timeline.isValidDuration(0))
    #expect(!Timeline.isValidDuration(.infinity))
}
```

`ParamValueTests.swift`:

```swift
@Test func aNonFiniteComponentIsZero() {
    #expect(ParamValue.float(.nan).finite == .float(0))
    #expect(ParamValue.float2(SIMD2(.infinity, 1)).finite == .float2(SIMD2(0, 1)))
    #expect(ParamValue.float4(SIMD4(1, -.infinity, .nan, 2)).finite == .float4(SIMD4(1, 0, 0, 2)))
    #expect(ParamValue.int(3).finite == .int(3))
    #expect(ParamValue.float(.nan).mslLiteral == "0.0")
    #expect(ParamValue.float3(SIMD3(.infinity, 0, 0)).mslLiteral == "float3(0.0, 0.0, 0.0)")
}
```
Check how `ParamValuesTests.swift` reaches the `ParamValues` literal function (`mslLiteral(_:as:)`) and add the same NaN case there: `.float(.nan)` as `.float` spells `"0.0"`.

`ShaderPackageTests.swift`:

```swift
@Test func anAssetExtensionIsSanitisedOnDecode() throws {
    let info = try JSONDecoder().decode(AssetInfo.self, from: Data(#"{"name":"x","fileExtension":"png/../y"}"#.utf8))
    #expect(info.fileExtension == "pngy")
    let empty = try JSONDecoder().decode(AssetInfo.self, from: Data(#"{"name":"x","fileExtension":"../"}"#.utf8))
    #expect(empty.fileExtension == "bin")
}
```
Match `AssetInfo`'s real keys (read its declaration first); if it has more required keys, include them.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MetalNodesKit && swift test --filter "GraphCodableTests|ShaderDocumentTests|ShaderPackageTests|GroupValidationTests|TimelineTests|ParamValueTests"`
Expected: the new tests fail to compile (missing members) or crash (`Fatal error: Duplicate values for key`). A trap kills the test process — run the trap tests last, or one at a time, to see the others' state.

- [ ] **Step 3: Implement**

`Persistence/DecodingSupport.swift`:

```swift
import Foundation

extension Dictionary {
    /// Builds a dictionary from `pairs`, throwing `DecodingError.dataCorrupted` on the first
    /// repeated key. `Dictionary(uniqueKeysWithValues:)` traps instead, and a decoder is exactly
    /// where input from outside the process arrives (spec §27.2): a hand-merged `document.json`
    /// or a crafted pasteboard must fail with a message, never crash the app.
    static func uniqueOrThrow<S: Sequence>(_ pairs: S, codingPath: [any CodingKey],
                                          describe: (Key) -> String) throws -> Self
    where S.Element == (Key, Value) {
        var out = Self(minimumCapacity: pairs.underestimatedCount)
        for (key, value) in pairs {
            guard out.updateValue(value, forKey: key) == nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: describe(key)))
            }
        }
        return out
    }
}
```

`Graph.swift` decoder:

```swift
public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    nodes = try .uniqueOrThrow(try c.decode([NodeInstance].self, forKey: .nodes).map { ($0.id, $0) },
                               codingPath: c.codingPath + [Keys.nodes]) { "duplicate node id \($0.raw.uuidString)" }
    inputs = try .uniqueOrThrow(try c.decode([Edge].self, forKey: .edges).map { ($0.to, $0.from) },
                                codingPath: c.codingPath + [Keys.edges]) { "two wires into \($0.node.raw.uuidString).\($0.socket)" }
    stickies = try .uniqueOrThrow((try c.decodeIfPresent([StickyNote].self, forKey: .stickies) ?? []).map { ($0.id, $0) },
                                  codingPath: c.codingPath + [Keys.stickies]) { "duplicate sticky id \($0.raw.uuidString)" }
    frames = try .uniqueOrThrow((try c.decodeIfPresent([CommentFrame].self, forKey: .frames) ?? []).map { ($0.id, $0) },
                                codingPath: c.codingPath + [Keys.frames]) { "duplicate frame id \($0.raw.uuidString)" }
}
```
`ShaderDocument` decoder: `definitions = try .uniqueOrThrow(…) { "duplicate definition id \($0.raw.uuidString)" }`. If `CommentID`/`GroupID` do not expose `raw`, use `"\($0)"`.

`ShaderPackage.init(fileWrapper:)`:

```swift
do {
    document = try JSONDecoder().decode(ShaderDocument.self, from: docData)
} catch DecodingError.dataCorrupted(let context) {
    throw .undecodable(context.debugDescription)
} catch {
    throw .undecodable(String(describing: error))
}
```

`TypeResolver.swift:48-49` — first wins, so nothing internal can trap; the validator below is what reports it:

```swift
inputTypes: Dictionary(def.inputs.filter { !NodeShape.isPlus($0) }.map { ($0.name, concrete($0.type)) }, uniquingKeysWith: { a, _ in a }),
outputTypes: Dictionary(def.outputs.filter { !NodeShape.isPlus($0) }.map { ($0.name, concrete($0.type)) }, uniquingKeysWith: { a, _ in a }))
```

`Validation.swift` — inside the definitions loop of `validate(document:)`, after the contains-itself check:

```swift
// Socket names are the function's parameter names (spec §20.4): two alike would trap the
// resolver's maps, and refuse here is what the user can act on (spec §27.2).
for (label, decls) in [("input", d.inputs), ("output", d.outputs)] {
    var seen = Set<String>()
    for decl in decls where !NodeShape.isPlus(decl) {
        if !seen.insert(decl.name).inserted {
            out.append(Diagnostic(.error, "Definition “\(d.name)” declares two \(label)s named “\(decl.name)”"))
        }
    }
}
```

`Timeline.swift`:

```swift
public struct Timeline: Sendable, Hashable, Codable {
    public var duration: Double = 4
    public var frameRate: Int = 60
    public var loops: Bool = true

    public static let frameRates = [24, 30, 60]
    /// The longest loop a document may hold; `EditorModel.setTimeline` refuses past it with a
    /// notice, and the decoder falls back to the default (spec §27.2).
    public static let maxDuration: Double = 3600

    public static func isValidDuration(_ d: Double) -> Bool { d.isFinite && d > 0 && d <= maxDuration }

    /// Frames in one pass, rounded to the nearest whole frame and never fewer than one.
    public var frameCount: Int { Self.frameCount(duration: duration, frameRate: frameRate) }

    /// Bounded in `Double` before the conversion: `Int(Double)` traps outside the `Int` range,
    /// and a timeline is a decoded value (spec §27.2).
    public static func frameCount(duration: Double, frameRate: Int) -> Int {
        let f = (duration * Double(frameRate)).rounded()
        guard f.isFinite else { return 1 }
        return Int(min(max(f, 1), 1e9))
    }

    public init(duration: Double = 4, frameRate: Int = 60, loops: Bool = true) { … }

    private enum Keys: String, CodingKey { case duration, frameRate, loops }

    /// Tolerant on purpose: a value no writer produces (the inspector and `setTimeline` both
    /// refuse it) is a hand edit, and the document is still worth opening.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let d = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 4
        duration = Self.isValidDuration(d) ? d : 4
        let r = try c.decodeIfPresent(Int.self, forKey: .frameRate) ?? 60
        frameRate = Self.frameRates.contains(r) ? r : 60
        loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(frameRate, forKey: .frameRate)
        try c.encode(loops, forKey: .loops)
    }
}
```
Encoding is spelled out so the key set stays exactly what the synthesised encoder wrote (`FormatCorpusTests` pins it). Leave `TimelineClock` alone in this task — Task 4 owns it.

`ParamValue.swift`:

```swift
/// The same value with every NaN or infinite component replaced by 0 (spec §27.2): the JSON
/// encoder cannot write a non-finite float, and Metal has no literal for one.
public var finite: ParamValue {
    func f(_ x: Float) -> Float { x.isFinite ? x : 0 }
    switch self {
    case .float(let x): return .float(f(x))
    case .float2(let v): return .float2(SIMD2(f(v.x), f(v.y)))
    case .float3(let v): return .float3(SIMD3(f(v.x), f(v.y), f(v.z)))
    case .float4(let v): return .float4(SIMD4(f(v.x), f(v.y), f(v.z), f(v.w)))
    case .int, .bool, .enumCase, .asset, .text: return self
    }
}
```
and in `mslLiteral`'s `f`: `guard x.isFinite else { return "0.0" }` as the first line. Same guard first in `ParamValues.f`. Match the real vector storage type (`SIMD2<Float>` etc.) — read the enum first.

`AssetInfo` decoder: add a custom `init(from:)` (keep the synthesised encoder) that reads `fileExtension` and stores `String(raw.filter { $0.isLetter || $0.isNumber })`, or `"bin"` when that is empty. Keep every other key as it decodes today.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command, then `swift test` (whole package) — `FormatCorpusTests`, `GraphCodableTests` and `DocumentSettingsTests` must be untouched.

- [ ] **Step 5: Mutation checks**

Revert, one at a time, the `uniqueOrThrow` use in `Graph.init`, the validator rule, the `Timeline` decoder and `finite`; each time the matching test must fail (the first by trapping). Restore. Record the four results in the report.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "fix(core): decode and validation paths report instead of trapping

Duplicate ids, duplicate socket names, out-of-range timelines, non-finite
parameters and path separators in an asset extension all reached a trap
or an unwritable document; each is now a diagnostic, a default, or zero."
```

---

### Task 2: The Expression scanner

Closes core review findings 2, 3, 7 and 9 (tokenise memo, shape once).

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MSLScanner.swift` (`Token`, `reservedNames`, `isFreeIdentifier` and its three callers, `tokenise`, `stripComments`), `Library/Builtin/ExpressionNode.swift`.
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MSLScannerTests.swift`, `ExpressionNodeTests.swift`.

**Interfaces:**
- Produces: `MSLScanner.stripComments(_:)` (internal), `MSLScanner.isTokeniseCached(_:)` (internal test probe), `ExpressionNode.sockets(forNames:)`/`generics(forNames:)`.

- [ ] **Step 1: Write the failing tests**

`MSLScannerTests.swift`:

```swift
@Test func aCallIsNeverASocket() {
    #expect(MSLScanner.identifiers(in: "fmod(a, 2.0)") == ["a"])
    #expect(MSLScanner.identifiers(in: "mn_hash21(uv) * k") == ["uv", "k"])
    #expect(MSLScanner.identifiers(in: "myHelper (x)") == ["x"])           // whitespace before the paren
    #expect(MSLScanner.identifiers(in: "fwidth(x) + dfdx(y)") == ["x", "y"])
}

@Test func stdlibConstantsAndPackedTypesAreReserved() {
    #expect(MSLScanner.identifiers(in: "a * M_PI_F + M_E_F") == ["a"])
    #expect(MSLScanner.identifiers(in: "select(INFINITY, NAN, b)") == ["b"])
    #expect(MSLScanner.identifiers(in: "packed_float3 p = q") == ["q"])
}

@Test func numericLiteralsScanAsMetalSpellsThem() {
    #expect(MSLScanner.identifiers(in: "0xFF + 1u + 0.5h + 2.0f + 3l") == [])
    #expect(MSLScanner.identifiers(in: "0x1p3 * a") == ["a"])
    // The rewrite leaves every literal byte-for-byte.
    let out = MSLScanner.rewritingIdentifiers(in: "0xFF * a + 1u") { "{in.\($0)}" }
    #expect(out == "0xFF * {in.a} + 1u")
}

@Test func identifiersAreASCII() {
    #expect(MSLScanner.identifiers(in: "π * r") == ["r"])
    #expect(MSLScanner.identifiers(in: "x² + y") == ["x", "y"])
}

@Test func tokenisingIsServedFromTheCache() {
    let body = "float k = a * \(UUID().uuidString.prefix(8)); out = k;"
    #expect(!MSLScanner.isTokeniseCached(body))
    _ = MSLScanner.identifiers(in: body)
    #expect(MSLScanner.isTokeniseCached(body))
    #expect(MSLScanner.identifiers(in: body) == ["a", "out"])
}
```
`x²`: `²` is a non-ASCII character between `x` and ` `, so `x` ends the identifier and `²` is a stray punctuation token — hence `["x", "y"]`.

`ExpressionNodeTests.swift` (uses the file's existing `shape(_:)`, `document(_:)` and `emits(_:_:)` helpers):

```swift
@Test func aBuiltinCallProducesNoSocketAndCompilesToACall() throws {
    #expect(shape("fmod(a, 2.0)").inputs.map(\.name) == ["a"])
    let src = try ShaderGenerator.generate(document("fmod(a, 2.0)"), registry: .builtin).source
    #expect(emits(src, #"fmod\(u\.p\d+, 2\.0\)"#))
}

@Test func aTrailingCommentDoesNotSwallowTheStatementsSemicolon() throws {
    let src = try ShaderGenerator.generate(document("a * 2.0 // half"), registry: .builtin).source
    #expect(emits(src, #"= u\.p\d+ \* 2\.0\s*;"#))
    #expect(!src.contains("// half;"))
}

@Test func aHexLiteralIsNotASocket() throws {
    #expect(shape("0xFF * a").inputs.map(\.name) == ["a"])
}
```
Match `emits`' real signature (it may take the pattern first). If `ShaderGenerator.generate(_:registry:)` is not the file's shorthand, use whichever overload the neighbouring tests use.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MetalNodesKit && swift test --filter "MSLScannerTests|ExpressionNodeTests"`
Expected: `aCallIsNeverASocket` reports `["fmod", "a"]`; `numericLiteralsScanAsMetalSpellsThem` reports `["xFF", "u", "h", "l"]`; `identifiersAreASCII` reports `["π", "r"]`; the cache probe fails to compile.

- [ ] **Step 3: Implement**

In `MSLScanner`:

1. `struct Token: Equatable, Sendable` — needed to hold tokens in a `Mutex` (a `static let Mutex<Value>` is only concurrency-safe when `Value: Sendable`; that is why `ScanCache<[Violation]>` compiles today).

2. Extend `reservedNames` with exactly this set, in a new `// stdlib functions a one-liner reaches for (spec §27.3)` group and a `// constants and packed types` group:
   `fmod fmin fmax fabs fwidth dfdx dfdy any all powr exp10 log10 rint sincos mad transpose determinant as_type ldexp frexp copysign nextafter fdim hypot precise fast`
   `M_PI_F M_PI_2_F M_PI_4_F M_1_PI_F M_2_PI_F M_E_F M_LN2_F M_LN10_F M_SQRT2_F INFINITY NAN MAXFLOAT packed_float2 packed_float3 packed_float4 packed_half2 packed_half3 packed_half4`.
   Add `packed_float`/`packed_half` prefixes to `isTypeName` so `packed_float3 p = q` declares `p`.

3. The call rule. `isFreeIdentifier` gains the token index so it can look one token ahead:

```swift
/// A socket is never called: an identifier immediately followed by `(` is a function call,
/// whatever its name — a builtin the list does not know, an `mn_` helper, a user's own function
/// (spec §27.3). Comments and whitespace never produce tokens, so "immediately" is the next token.
private static func isCall(_ tokens: [Token], at i: Int) -> Bool {
    i + 1 < tokens.count && tokens[i + 1].kind == .punctuation && tokens[i + 1].text == "("
}

private static func isFreeIdentifier(_ tokens: [Token], at i: Int, declared: Set<String>) -> Bool {
    let t = tokens[i]
    return t.kind == .identifier && !t.afterDot && !reservedNames.contains(t.text)
        && !declared.contains(t.text) && !isCall(tokens, at: i)
}
```
   and every loop over `tokens where isFreeIdentifier(t, …)` becomes `for i in tokens.indices where isFreeIdentifier(tokens, at: i, declared: declared) { let t = tokens[i] … }` in `identifiers(in:)`, `identifierLines(in:)` and `rewritingIdentifiers(in:with:)`.

4. Numbers, in `tokenise`. Replace the `if c.isNumber { … }` block:

```swift
if c.isNumber {
    let start = i
    var s = ""
    let isHex = c == "0" && i + 1 < chars.count && (chars[i + 1] == "x" || chars[i + 1] == "X")
    if isHex {
        s.append(chars[i]); s.append(chars[i + 1]); i += 2
        while i < chars.count, chars[i].isHexDigit || chars[i] == "." || chars[i] == "p" || chars[i] == "P"
            || ((chars[i] == "-" || chars[i] == "+") && (s.last == "p" || s.last == "P")) {
            s.append(chars[i]); i += 1
        }
    } else {
        while i < chars.count, chars[i].isNumber || chars[i] == "." || chars[i] == "e" || chars[i] == "E"
            || ((chars[i] == "-" || chars[i] == "+") && (s.last == "e" || s.last == "E")) {
            s.append(chars[i]); i += 1
        }
    }
    // MSL's suffixes (`1u`, `0.5h`, `2.0f`, `3l`) belong to the literal, not to a following name.
    while i < chars.count, "uUhHfFlL".contains(chars[i]) {
        s.append(chars[i]); i += 1
    }
    out.append(Token(kind: .number, text: s, line: line, afterDot: false, start: start))
    afterDot = false
    continue
}
```
   `Character.isHexDigit` exists. Note the decimal loop no longer eats `f`/`F` inside the body — the suffix loop takes them, so `1e5f` still scans as one token.

5. ASCII identifiers: the start test becomes `(c.isASCII && c.isLetter) || c == "_"` and the continue test `(chars[i].isASCII && (chars[i].isLetter || chars[i].isNumber)) || chars[i] == "_"`. A non-ASCII letter now falls through to the punctuation branch as a one-character token.

6. `stripComments` becomes `static func stripComments(_:)` (internal, no other change).

7. The tokenise memo, next to `scopeBreakerCache`:

```swift
/// `tokenise` memoised per source text (spec §27.3): every entry point over one body —
/// identifiers, lines, accessor call sites, scope breakers, loop sites — shares the one hit.
private static let tokenCache = Mutex(ScanCache<[Token]>(capacity: 64))

static func tokenise(_ source: String) -> [Token] {
    tokenCache.withLock { $0.value(for: source) { uncachedTokenise(source) } }
}

static func isTokeniseCached(_ source: String) -> Bool {
    tokenCache.withLock { $0.contains(source) }
}
```
   Rename the existing body to `private static func uncachedTokenise(_:)`. Keep whatever line-ending normalisation `tokenise` did today inside `uncachedTokenise`.

In `ExpressionNode`:

```swift
public static func sockets(forFormula formula: String) -> [SocketDecl] { sockets(forNames: MSLScanner.identifiers(in: formula)) }
public static func generics(forFormula formula: String) -> [String: [SocketType]] { generics(forNames: MSLScanner.identifiers(in: formula)) }

static func sockets(forNames names: [String]) -> [SocketDecl] {
    names.enumerated().map { i, name in
        SocketDecl(name: name, label: name, type: .generic("T\(i)"), default: .value(.float(0)))
    }
}

static func generics(forNames names: [String]) -> [String: [SocketType]] {
    var out: [String: [SocketType]] = [:]
    for i in names.indices { out["T\(i)"] = BuiltinNodes.anyFloat }
    return out
}
```
`shape(for:)` computes `let names = MSLScanner.identifiers(in: formula)` once and passes it to both. `template(for:)`:

```swift
// A `//` comment at the end of the formula would otherwise swallow the `;` this template
// appends (spec §27.3). Blanking keeps the line count, so `userLines` is unaffected.
let stripped = MSLScanner.stripComments(MSLScanner.normalisedLineEndings(formula))
let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
```
`normalisedLineEndings` is `static` internal today — confirm, and make it so if not.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command, then `swift test`. Every existing scanner, loop-hardening, custom-code and corpus test must still pass: if `LoopHardeningTests` or `CustomCodeValidationTests` fail, the number scanner or the ASCII rule changed a token boundary they pin — fix the scanner, not the test, unless the pinned behaviour is one §27.3 changes on purpose.

- [ ] **Step 5: Mutation checks**

Revert `isCall`, the suffix loop, the ASCII rule, the comment strip and the memo one at a time; the matching test must fail each time. Record.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "fix(core): an Expression call is never a socket; MSL literals and ASCII identifiers

Widens the reserved list, adds the call rule, scans hex and suffixed
literals as one token, strips a trailing comment before the template's
semicolon, and memoises tokenise."
```

---

### Task 3: Graph traversal cost

Closes core review findings 10 and 11.

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/TopoSort.swift`, `Codegen/Validation.swift:167-171` (the cycle walk's `sources(of:)`), `ShaderDocument.swift:298-304` (`node(_:)`).
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TopoSortTests.swift`.

**Interfaces:**
- Produces: `TopoSort.sourcesByNode(_:)` (internal).

- [ ] **Step 1: Write the failing test**

```swift
@Test func theReverseAdjacencyListsEverySourceInSortedOrder() {
    let doc = ShaderDocument.sample()
    let map = TopoSort.sourcesByNode(doc.root)
    for (to, from) in doc.root.inputs where doc.root.nodes[from.node] != nil {
        #expect(map[to.node]?.contains(from.node) == true)
    }
    for (_, sources) in map {
        #expect(sources == sources.sorted { $0.raw.uuidString < $1.raw.uuidString })
        #expect(Set(sources).count == sources.count)
    }
    #expect(map.values.allSatisfy { !$0.isEmpty })
}

@Test func orderIsUnchangedByTheAdjacencyRewrite() {
    // The pre-M11 walk, kept here as the reference the fast one must reproduce.
    func reference(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
        var result: [NodeID] = [], done = Set<NodeID>()
        func sources(of n: NodeID) -> [NodeID] {
            var s = Set<NodeID>()
            for (to, from) in graph.inputs where to.node == n && graph.nodes[from.node] != nil { s.insert(from.node) }
            return s.sorted { $0.raw.uuidString < $1.raw.uuidString }
        }
        var stack: [(NodeID, [NodeID])] = [(terminal, sources(of: terminal))]
        var onStack: Set<NodeID> = [terminal]
        while let top = stack.last {
            let n = top.0; var pending = top.1
            if let next = pending.popLast() {
                stack[stack.count - 1] = (n, pending)
                if !done.contains(next) && !onStack.contains(next) { onStack.insert(next); stack.append((next, sources(of: next))) }
            } else { stack.removeLast(); onStack.remove(n); if done.insert(n).inserted { result.append(n) } }
        }
        return result
    }
    for doc in [ShaderDocument.sample(), ShaderDocument.starter()] + SampleDocuments.all.map(\.document) {
        for graph in [doc.root] + doc.definitions.values.map(\.graph) {
            for id in graph.nodes.keys {
                #expect(TopoSort.order(graph, from: id) == reference(graph, from: id))
            }
        }
    }
}
```
Use whatever `SampleDocuments` actually exposes (grep `SampleDocuments` in `Library/SampleDocuments.swift`); if there is no `.all`, list the samples the file defines.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd MetalNodesKit && swift test --filter TopoSortTests`
Expected: `sourcesByNode` does not exist.

- [ ] **Step 3: Implement**

`TopoSort.swift`:

```swift
public enum TopoSort {
    /// Every node's sources, each list in sorted-uuid order, built once per traversal so the
    /// walk is O(N + E) instead of a scan of every wire per visited node (spec §27.4).
    static func sourcesByNode(_ graph: Graph) -> [NodeID: [NodeID]] {
        var sets: [NodeID: Set<NodeID>] = [:]
        for (to, from) in graph.inputs where graph.nodes[from.node] != nil {
            sets[to.node, default: []].insert(from.node)
        }
        return sets.mapValues { $0.sorted { $0.raw.uuidString < $1.raw.uuidString } }
    }

    public static func order(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
        order(graph, from: terminal, sources: sourcesByNode(graph))
    }

    private static func order(_ graph: Graph, from terminal: NodeID, sources: [NodeID: [NodeID]]) -> [NodeID] {
        var result: [NodeID] = []
        var done = Set<NodeID>()
        var stack: [(NodeID, [NodeID])] = [(terminal, sources[terminal] ?? [])]
        var onStack: Set<NodeID> = [terminal]
        while let top = stack.last {
            let n = top.0
            var pending = top.1
            if let next = pending.popLast() {
                stack[stack.count - 1] = (n, pending)
                if !done.contains(next) && !onStack.contains(next) {
                    onStack.insert(next)
                    stack.append((next, sources[next] ?? []))
                }
            } else {
                stack.removeLast()
                onStack.remove(n)
                if done.insert(n).inserted { result.append(n) }
            }
        }
        return result
    }

    public static func orderAll(_ graph: Graph) -> [NodeID] {
        let sources = sourcesByNode(graph)
        var result: [NodeID] = []
        var done = Set<NodeID>()
        for id in graph.nodes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) where !done.contains(id) {
            for n in order(graph, from: id, sources: sources) where !done.contains(n) {
                done.insert(n)
                result.append(n)
            }
        }
        return result
    }
}
```

`Validation.swift` cycle walk: replace the local `sources(of:)` with `let sources = TopoSort.sourcesByNode(graph)` and `sources[start] ?? []` / `sources[next] ?? []`. The old closure returned sources in dictionary order (unspecified); the new one is sorted, which only affects the order of "Wires form a cycle" diagnostics on a graph with several cycles.

`ShaderDocument.node(_:)`: drop the `.sorted(by:)` — iterate `definitions.values` directly; update the doc comment: ids are unique document-wide (ruling R12), so any hit is the hit.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test` (the whole package — `FormatCorpusTests` and every codegen suite pin the emitted order).

- [ ] **Step 5: Mutation check**

Make `sourcesByNode` skip the sort; `theReverseAdjacencyListsEverySourceInSortedOrder` must fail on at least one sample (if every node in the samples has ≤ 1 source, add a three-source node to the first test's graph so the assertion has teeth). Restore.

- [ ] **Step 6: Commit**

```bash
git commit -am "perf(core): one reverse adjacency per traversal; node lookup without the sort"
```

---

### Task 4: The clock's end state and retargeting

Closes editor review findings 9 and 12 (Core half; Task 8 does the model half).

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Timeline.swift` (`TimelineClock.seek`, `retarget`).
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TimelineTests.swift` (`TimelineClockTests`).

- [ ] **Step 1: Write the failing tests**

```swift
@Test func seekingPastTheEndStopsTheClockInWallClockMode() {
    var c = TimelineClock(timeline: Timeline(duration: 1, frameRate: 60, loops: false), mode: .wallClock)
    c.seek(elapsed: 0.5)
    #expect(c.frame == 30)
    #expect(c.isPlaying)
    #expect(c.elapsedSeconds == 0.5)
    c.seek(elapsed: 5)
    #expect(c.frame == 59)
    #expect(!c.isPlaying)
    #expect(c.elapsedSeconds == 1)          // the readout stops at the duration
    c.seek(elapsed: 1e300)                  // bounded before the Int conversion
    #expect(c.frame == 59)
    c.seek(elapsed: .nan)
    #expect(c.frame == 0)
}

@Test func retargetingPreservesTimeNotTheFrameIndex() {
    var c = TimelineClock(timeline: Timeline(duration: 4, frameRate: 60, loops: true), mode: .fixedRate)
    c.frame = 100                            // 1.667 s
    c.retarget(Timeline(duration: 4, frameRate: 24, loops: true), mode: .fixedRate)
    #expect(c.frame == 40)                   // round(1.667 × 24)
    c.retarget(Timeline(duration: 1, frameRate: 30, loops: false), mode: .fixedRate)
    #expect(c.frame == 29)                   // 1.667 s is past a 1 s clip: clamped to the end
}
```
Read the existing `TimelineClockTests` for a test that asserts `elapsedSeconds` keeps counting past the end (spec §26.3's old wording) and change its expectation to the §27.5 behaviour, citing the section in a comment.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MetalNodesKit && swift test --filter TimelineClockTests`
Expected: `isPlaying` stays true past the end; the retarget test reports frame 95.

- [ ] **Step 3: Implement**

```swift
/// Wall clock: place the clock at `elapsed` seconds of play. Wraps modulo the loop's duration
/// when looping; with loops off the clock stops at the last frame, exactly as `step()` does, and
/// the readout stops at the duration (spec §27.5).
public mutating func seek(elapsed: Double) {
    let safe = elapsed.isFinite ? elapsed : 0
    let scaled = (safe * Double(timeline.frameRate)).rounded(.down)
    let raw = Int(min(max(scaled, -1e9), 1e9))
    if timeline.loops {
        elapsedSeconds = safe
        frame = ((raw % timeline.frameCount) + timeline.frameCount) % timeline.frameCount
    } else if raw >= timeline.frameCount - 1 {
        frame = timeline.frameCount - 1
        elapsedSeconds = timeline.duration
        isPlaying = false
    } else {
        elapsedSeconds = safe
        frame = max(raw, 0)
    }
}

/// A settings change keeps the *time*, not the frame index: a new frame rate re-scales what an
/// index means, and a user changing 60 → 24 fps at 1.67 s expects to stay at 1.67 s (spec §27.5).
public mutating func retarget(_ timeline: Timeline, mode: TimeMode) {
    let t = Double(frame) / Double(self.timeline.frameRate)
    self.timeline = timeline
    self.mode = mode
    frame = min(max(Int((t * Double(timeline.frameRate)).rounded()), 0), timeline.frameCount - 1)
}
```
`t` is at most `1e9 / 24` seconds, so the `Int` conversion cannot trap.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "TimelineClockTests|TimelineTests"`, then `swift test`. `EditorClockSyncTests` (UI) must still pass: `changingTheTimelineRetargetsTheClock` expects frame 29 from frame 100 @ 60 into 1 s @ 30 — 1.667 s clamps to 29 either way.

- [ ] **Step 5: Mutation check.** Revert `isPlaying = false`; the end-state test must fail. Restore.

- [ ] **Step 6: Commit**

```bash
git commit -am "fix(core): the wall clock stops at the end; retargeting keeps the time"
```

---

### Task 5: The recording pipeline

Closes render review findings 1, 6 (depth), 7, 8, 9, 11, 16 and the video colour tag of 3.

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/Recording/VideoSink.swift`, `Recording/FrameSink.swift`, `Recording/ExportSession.swift`; every `FrameSink` conformer in the tests (grep `: FrameSink` under `MetalNodesKit/Tests`).
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/VideoSinkTests.swift`, `FrameSinkTests.swift`, `ExportSessionTests.swift`.

**Interfaces:**
- Produces: `VideoSink.maxEdge`, `VideoSink.maxPixels`, `VideoSink.isSizeSupported(width:height:)`; `ExportSession.maxPixels`, `ExportSession.isSizeSupported(_:)`; `FrameSink.begin(width:height:frameRate:frameCount:)`; `RecordingError.encodeFailed(String)`.
- Task 7 uses both `isSizeSupported`s in the size sheet.

- [ ] **Step 1: Write the failing tests**

`VideoSinkTests.swift`:

```swift
@Test func theH264CeilingIsLevel6_2() {
    #expect(VideoSink.isSizeSupported(width: 8192, height: 4352))       // 35,651,584 exactly
    #expect(!VideoSink.isSizeSupported(width: 8192, height: 4354))
    #expect(VideoSink.isSizeSupported(width: 8192, height: 8192) == false)
    #expect(!VideoSink.isSizeSupported(width: 8194, height: 16))
    #expect(!VideoSink.isSizeSupported(width: 0, height: 16))
    #expect(VideoSink.isSizeSupported(width: 7680, height: 4320))
}

@Test func beginRefusesAnOversizedVideoBeforeAnyFrame() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID()).mp4")
    let sink = VideoSink(url: url)
    await #expect(throws: RecordingError.sizeUnsupported(CGSize(width: 8192, height: 8192))) {
        try await sink.begin(width: 8192, height: 8192, frameRate: 60, frameCount: 1)
    }
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func aOneFrameVideoIsOneFrameLong() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID()).mp4")
    defer { try? FileManager.default.removeItem(at: url) }
    let sink = VideoSink(url: url)
    try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 1)
    try await sink.write(frame(0, width: 64, height: 64), index: 0)
    try await sink.finish()
    let duration = try await AVURLAsset(url: url).load(.duration)
    #expect(abs(duration.seconds - 1.0 / 30.0) < 0.001)
}

@Test func finishAfterAbandonIsANoOpNotACrash() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID()).mp4")
    let sink = VideoSink(url: url)
    try await sink.begin(width: 64, height: 64, frameRate: 30, frameCount: 2)
    await sink.abandon()
    await sink.abandon()                                    // idempotent
    await #expect(throws: RecordingError.self) { try await sink.finish() }
}
```
The existing 12-frame test keeps its 0.2 s expectation; update its `begin` call for the new parameter. `#expect(throws:)` with an `async` body: check the local Swift Testing spelling (`await #expect(throws:) { try await … }`) compiles; if not, use a `do/catch` with `Issue.record`.

`FrameSinkTests.swift`:

```swift
@Test func frameNamesPadToTheSequenceLength() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let sink = ImageSequenceSink(directory: dir, baseName: "clip")
    try await sink.begin(width: 4, height: 4, frameRate: 60, frameCount: 10_000)
    try await sink.write(FrameBytes(width: 4, height: 4, bytesPerRow: 16, bgra: [UInt8](repeating: 0, count: 64)), index: 0)
    try await sink.write(FrameBytes(width: 4, height: 4, bytesPerRow: 16, bgra: [UInt8](repeating: 0, count: 64)), index: 9_999)
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(names == ["clip_00001.png", "clip_10000.png"])
}
```

`ExportSessionTests.swift`:

```swift
@Test func sizesAreBoundedByEdgeAndByPixels() {
    #expect(ExportSession.isSizeSupported(CGSize(width: 16384, height: 4096)))
    #expect(ExportSession.isSizeSupported(CGSize(width: 8192, height: 8192)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: 8193, height: 8192)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: 16385, height: 1)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: -1, height: 8)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: 0.4, height: 8)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: .infinity, height: 8)))
    #expect(!ExportSession.isSizeSupported(CGSize(width: -1e300, height: 8)))
}
```
and, next to `anOversizedFrameIsRefusedAsASizeProblem`, a GPU test that `init` with `-1 × 8` throws `sizeUnsupported` (same skeleton as the existing one).

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MetalNodesKit && swift test --filter "VideoSinkTests|FrameSinkTests|ExportSessionTests"`
Expected: compile failures on the new members and the `frameCount:` label.

- [ ] **Step 3: Implement**

`FrameSink.swift`:

```swift
public protocol FrameSink: Sendable {
    /// `frameCount` is the number of `write`s to expect, so a sink can size what depends on it
    /// (the sequence's zero padding, spec §27.6).
    func begin(width: Int, height: Int, frameRate: Int, frameCount: Int) async throws
    …
}
```
`ImageSequenceSink` stores `private let padding = Mutex(4)`? No — it is `Sendable` with `let`s only. Make it `public final class ImageSequenceSink: FrameSink, @unchecked Sendable` with `private var padding = 4` written once in `begin` before any `write` (state the reason in a comment: written once in `begin`, read afterwards, and the session never overlaps the two). In `begin`: `padding = max(4, String(frameCount).count)`. In `write`:

```swift
let number = String(index + 1)
let name = singleFileName ?? baseName + "_" + String(repeating: "0", count: max(0, padding - number.count)) + number + ".png"
```

`RecordingError`: add `case encodeFailed(String)` with description `"The frame could not be rendered: \(why)"`.

`VideoSink.swift`:

```swift
import CoreGraphics   // CGSize in the size error

/// H.264 level 6.2: 8192 per edge and 139,264 macroblocks (35,651,584 pixels). VideoToolbox
/// accepts every `append` above this and only fails at `finishWriting`, after the whole render
/// (spec §27.6) — so the bound is stated here and checked before the first frame.
public static let maxEdge = 8192
public static let maxPixels = 35_651_584

public static func isSizeSupported(width: Int, height: Int) -> Bool {
    width >= 1 && height >= 1 && width <= maxEdge && height <= maxEdge && width * height <= maxPixels
}

private var lastIndex = -1      // under `queue`, like the writer
```
`begin`: first line `guard Self.isSizeSupported(width: width, height: height) else { throw RecordingError.sizeUnsupported(CGSize(width: width, height: height)) }` (before `queue.sync`, before removing any file); `lastIndex = -1` inside the sync block; settings gain

```swift
AVVideoColorPropertiesKey: [
    AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
],
```
`write`: after a successful `append`, `lastIndex = index`. `finish`:

```swift
public func finish() async throws {
    // `endSession` makes the duration `frameCount / frameRate` by construction rather than by the
    // writer's inference from the previous sample's delta — which for one sample is 1/15 s.
    let (finishingWriter, failure): (AVAssetWriter?, String?) = queue.sync {
        guard let writer, let input else { return (nil, nil) }
        guard writer.status == .writing else {
            return (nil, writer.error?.localizedDescription ?? "the writer stopped")
        }
        if lastIndex >= 0 {
            writer.endSession(atSourceTime: CMTime(value: CMTimeValue(lastIndex + 1), timescale: CMTimeScale(frameRate)))
        }
        input.markAsFinished()
        return (writer, nil)
    }
    if let failure { throw RecordingError.writerFailed(failure) }
    guard let finishingWriter else { throw RecordingError.writerFailed("no writer was begun") }
    await finishingWriter.finishWriting()
    try queue.sync {
        if finishingWriter.status != .completed {
            throw RecordingError.writerFailed(finishingWriter.error?.localizedDescription ?? "finishWriting")
        }
    }
}

public func abandon() async {
    queue.sync {
        if let writer, writer.status == .writing { writer.cancelWriting() }
        writer = nil; input = nil; adaptor = nil
    }
    try? FileManager.default.removeItem(at: url)
}
```
`ExportSession.swift`:

```swift
public static let maxDimension = 16384
/// 8192 × 8192: past this the colour target, the readback and the encoder's copy together
/// exceed what a machine with 8 GB can give one frame (spec §27.6).
public static let maxPixels = 8192 * 8192

/// Finite, at least one pixel on each edge, within `maxDimension` per edge and `maxPixels` in all.
public static func isSizeSupported(_ size: CGSize) -> Bool {
    guard size.width.isFinite, size.height.isFinite else { return false }
    let w = size.width.rounded(), h = size.height.rounded()
    guard w >= 1, h >= 1, w <= CGFloat(maxDimension), h <= CGFloat(maxDimension) else { return false }
    return w * h <= CGFloat(maxPixels)
}
```
`init`: replace the existing guard with `guard Self.isSizeSupported(spec.size) else { throw RecordingError.sizeUnsupported(spec.size) }`; the `max(1, …)` clamps can stay. `target(_:)` gains a `memoryless: Bool` parameter:

```swift
// The depth attachment is cleared and never stored (`.dontCare`), so on a GPU that supports
// it the texture needs no memory at all (spec §27.6).
d.storageMode = memoryless && device.supportsFamily(.apple1) ? .memoryless : .private
```
called with `false` for colour and `true` for depth. `run`: `sink.begin(width:height:frameRate: timeline.frameRate, frameCount: count)`. `renderFrame`: the `encode` failure throws `.encodeFailed("the frame could not be encoded")` and `cmd.error` throws `.encodeFailed(error.localizedDescription)`.

Update every test double conforming to `FrameSink` for the new `begin` signature.

- [ ] **Step 4: Run the tests to verify they pass**

Run: the Step 2 command, then `swift test`, then both `xcodebuild`s (the app target compiles the Render module for iOS — `supportsFamily(.apple1)` and `.memoryless` must resolve on both platforms):

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E "warning:|error:|BUILD"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "warning:|error:|BUILD"
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```

- [ ] **Step 5: Mutation checks.** Revert the `begin` guard, `endSession`, and the padding one at a time; the matching tests must fail. Record.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "fix(render): H.264 ceiling checked first, exact video duration, memoryless depth

VideoSink states level 6.2's bound and refuses above it in begin; finish
ends the session at the last frame so a one-frame video is one frame
long, and finish/abandon act only on a writing writer. ExportSession
bounds a frame by pixel count as well as edge, uses a memoryless depth
attachment where the GPU allows, and names GPU failures as such.
Sequences pad frame names to the sequence length."
```

---

### Task 6: Preview draw rate and colour

Closes render review findings 3 (preview half), 5 and 15.

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift:44-62`, `PreviewView.swift:15-33`.
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift` (`PreviewClockTests`).

- [ ] **Step 1: Write the failing test**

```swift
@Test func theDrawRateFollowsAFixedRateTimeline() {
    #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 24), mode: .fixedRate)) == 24)
    #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 30), mode: .fixedRate)) == 30)
    #expect(ShaderRenderer.preferredFrameRate(for: TimelineClock(timeline: Timeline(duration: 1, frameRate: 24), mode: .wallClock)) == 60)
}
```

- [ ] **Step 2: Run it to verify it fails** — `swift test --filter PreviewClockTests`: no such member.

- [ ] **Step 3: Implement**

`ShaderRenderer`:

```swift
/// The draw rate the clock wants (spec §27.7): in `.fixedRate` mode one draw is one frame, so
/// the view must draw at the timeline's rate for the preview to play at 1×; the wall clock is
/// placed by elapsed time and draws at the display's 60.
public static func preferredFrameRate(for clock: TimelineClock) -> Int {
    clock.mode == .fixedRate ? clock.timeline.frameRate : 60
}
```
In `draw(in:)`, before the mode switch:

```swift
// Set from the draw, not from `updateNSView`: the representable would have to read `clock` to
// know, and `clock` is rewritten every wall-clock frame — the update would run at 60 Hz.
let wanted = Self.preferredFrameRate(for: state.clock)
if view.preferredFramesPerSecond != wanted { view.preferredFramesPerSecond = wanted }
```
The wall-clock branch writes only on change:

```swift
case .wallClock:
    if state.clock.isPlaying {
        let now = CACurrentMediaTime()
        let started: Double
        if let s = state.playStartedAt { started = s } else { started = now; state.playStartedAt = now }
        var next = state.clock
        next.seek(elapsed: state.pausedElapsed + (now - started))
        // `clock` is observable: an unchanged value written 60×/s would re-evaluate the preview
        // controls at the display's rate even for a 24 fps timeline (spec §27.5).
        if next != state.clock { state.clock = next }
    } else if let started = state.playStartedAt { … unchanged … }
```
`PreviewView.makeView`:

```swift
// Without a colour space the layer does no colour matching and the shader's bytes are shown in
// the display's native primaries — P3 on every current Mac and iPad — while the PNG and the
// video are tagged sRGB. One tag for all three (spec §27.6).
#if os(macOS)
v.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
#else
(v.layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
#endif
```
`MTKView.colorspace` exists on macOS only; on iOS reach the layer. Add `import QuartzCore` if `CAMetalLayer` does not resolve.

- [ ] **Step 4: Run the tests** — `swift test --filter "PreviewClockTests|PreviewDrawTests"`, then both `xcodebuild`s (the iOS branch), `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Mutation check.** Make `preferredFrameRate` return 60 always; the test fails. Restore.

- [ ] **Step 6: Commit**

```bash
git commit -am "fix(render): fixed-rate preview draws at the timeline's rate; sRGB preview; guarded clock writes"
```

---

### Task 7: The recording flow in the editor

Closes editor review findings 1, 2, 3, 7, 13, 14 and render finding 2.

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Recording.swift:78-84`, `EditorModel.swift:66-70` (`recordingTask`) and `reload(package:)` (grep `func reload`), `EditorView.swift:44-94, 330-342`, `RecordingSheet.swift`, `EditorCommands.swift:68-71`, `EditorViewPad.swift:143-145`.
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift`.

**Interfaces:**
- Consumes: `VideoSink.isSizeSupported`, `ExportSession.isSizeSupported` (Task 5).
- Produces: `EditorModel.isRecording` (observed), `RecordingSizeSheet.isValid(kind:width:height:)`, `RecordingSizeSheet.limitText(for:)`.

- [ ] **Step 1: Write the failing tests**

Find the compiler double the file uses (`RecordingCompiler`) and how a failing compile is staged elsewhere in the UI tests (grep `.failure(` in `MetalNodesUITests`). If no double can fail, add to the test file:

```swift
/// Compiles nothing: every request fails, so `preview.lastError` is set and the last-good
/// pipeline (none) stays — the state a bad Custom Code body puts the editor in.
private final class FailingCompiler: ShaderCompiling {
    func compile(_ shader: GeneratedShader, generation: UInt64, fastMath: Bool) async -> CompileResult {
        .failure(message: "boom", lines: [], generation: generation)
    }
}
```
Match `ShaderCompiling`'s real protocol requirements and the `.failure` case's real labels (read `ShaderCompiling.swift`).

```swift
@Test func aGraphWhoseMetalCompileFailsIsRefusedForRecording() async {
    let m = EditorModel(document: .sample(), compiler: FailingCompiler())
    m.start()
    await m.awaitIdle()
    #expect(m.preview.lastError != nil)
    let dest = MemoryRecordingDestination()
    let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: MTLCreateSystemDefaultDevice(),
                                 destination: dest) { _ in }
    #expect(outcome == .failed("The graph has errors; fix them before recording."))
    #expect(dest.placed.isEmpty)
}

@Test func recordingWaitsForAnInFlightCompile() async throws {
    guard let device = MTLCreateSystemDefaultDevice() else { return }
    let m = EditorModel(document: .sample(), compiler: try ShaderCompiler(device: device))
    m.debounceInterval = .milliseconds(200)
    m.start()
    await m.awaitIdle()
    // An edit that is still inside its debounce when `record` is called.
    let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
    m.apply(.setTitle(uv.id, "Edited"))
    let dest = MemoryRecordingDestination()
    let outcome = await m.record(.snapshot, size: CGSize(width: 8, height: 8), device: device, destination: dest) { _ in }
    #expect(outcome == .saved)
    #expect(m.diagnostics.isEmpty)
}

@Test func reloadingCancelsARunningRecording() {
    let m = EditorModel(document: .sample(), compiler: RecordingCompiler())
    let task = Task<Void, Never> { try? await Task.sleep(for: .seconds(10)) }
    m.recordingTask = task
    #expect(m.isRecording)
    m.reload(package: ShaderPackage(document: .sample()))
    #expect(task.isCancelled)
    #expect(!m.isRecording)
    #expect(m.recordingTask == nil)
}

@Test func theSizeSheetBoundsVideoAndImagesDifferently() {
    #expect(RecordingSizeSheet.isValid(kind: .snapshot, width: 16384, height: 4096))
    #expect(!RecordingSizeSheet.isValid(kind: .video, width: 16384, height: 4096))
    #expect(RecordingSizeSheet.isValid(kind: .video, width: 7680, height: 4320))
    #expect(!RecordingSizeSheet.isValid(kind: .imageSequence, width: 8193, height: 8192))
    #expect(!RecordingSizeSheet.isValid(kind: .video, width: 0, height: 10))
    #expect(RecordingSizeSheet.limitText(for: .video).contains("8192"))
}
```
`MemoryRecordingDestination.placed` — use the real name of its recorded-placements property. `ExportOutcome` must be `Equatable` for `==`; if it is not, match with `if case`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd MetalNodesKit && swift test --filter EditorRecordingTests`
Expected: the first test gets `.saved` or a crash (recording a nil program is refused today only by `preview.program != nil` — with `FailingCompiler` there is no program, so it fails "correctly" for the wrong reason: add to the test a first successful compile with `RecordingCompiler`, then swap? `compiler` is `let`. Instead assert the reason directly: after the failing compile, `m.preview.program == nil` but the message must be the graph-errors one — and add the second, decisive check: a model whose `RecordingCompiler` succeeded once and *then* fails. If `RecordingCompiler` cannot be told to fail, give `FailingCompiler` a `failAfter: Int` counter so the first compile succeeds and the second fails; `apply(.setTitle…)` of a Custom Code body then reproduces the stale-program state exactly.) `isRecording`, `isValid(kind:…)` do not compile.

- [ ] **Step 3: Implement**

`EditorModel+Recording.record`:

```swift
// The last-good pipeline is never recorded in place of the document's program (spec §27.6):
// settle any pending compile first, then refuse on any error the editor is showing.
await awaitIdle()
guard (try? exportFiles()) != nil, preview.lastError == nil,
      !diagnostics.contains(where: { $0.severity == .error }), preview.program != nil else {
    return .failed("The graph has errors; fix them before recording.")
}
```
`EditorModel`:

```swift
/// The running recording, so the progress sheet's Cancel can reach it. Not observed itself;
/// `isRecording` is the observed mirror the menus disable on (spec §27.6).
@ObservationIgnored public var recordingTask: Task<Void, Never>? {
    didSet { isRecording = recordingTask != nil }
}
public private(set) var isRecording = false
```
In `reload(package:)`, first lines: `recordingTask?.cancel(); recordingTask = nil` with a comment (a Revert To Saved mid-recording would otherwise record the pre-revert program and then place it).

`EditorView`:

```swift
private enum RecordingPhase: Identifiable {
    case size(RecordingKind)
    case progress
    /// An early failure — graph errors, a refused size, a writer that would not start — shown in
    /// the sheet that is already up. Dismissing the sheet and raising an alert in one update is
    /// exactly what SwiftUI drops (spec §27.6).
    case failed(String)
    var id: Int { 0 }
}
```
sheet: `case .failed(let message): RecordingFailedSheet(message: message) { recordingPhase = nil }`. `startRecording`'s task tail:

```swift
model.recordingTask = nil
switch outcome {
case .failed(let message):
    if recordingPhase != nil { recordingPhase = .failed(message) } else { exportError = message }
default:
    recordingPhase = nil
}
```
and on the root view, next to the `.sheet`: `.onDisappear { model.recordingTask?.cancel() }` with a comment (a recording dies with its window; a placement panel must never appear for a closed document).

`RecordingSheet.swift`:

```swift
/// What each kind can be rendered at (spec §27.6): H.264 has its own ceiling, images a pixel budget.
static func isValid(kind: RecordingKind, width: Int, height: Int) -> Bool {
    kind == .video ? VideoSink.isSizeSupported(width: width, height: height)
                   : ExportSession.isSizeSupported(CGSize(width: width, height: height))
}

static func limitText(for kind: RecordingKind) -> String {
    kind == .video
        ? "H.264 video is limited to 8192 × 8192 and 35.6 megapixels."
        : "Width and height must be between 1 and \(ExportSession.maxDimension) px, and at most \(ExportSession.maxPixels) pixels together."
}
```
`isValid` (instance) → `Self.isValid(kind: kind, width: width, height: height)`; the red caption → `Text(Self.limitText(for: kind))`; both Cancel buttons gain `.keyboardShortcut(.cancelAction)`. New view:

```swift
struct RecordingFailedSheet: View {
    let message: String
    let onDismiss: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export failed").font(.headline)
            Text(message).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("OK", action: onDismiss).keyboardShortcut(.defaultAction) }
        }
        .padding(20)
        .frame(width: 360)
    }
}
```
Menus: `EditorCommands` recording buttons `.disabled(model == nil || model?.isRecording == true)`; `EditorViewPad` `.disabled(model.isRecording)`.

- [ ] **Step 4: Run the tests** — `swift test --filter EditorRecordingTests`, `swift test`, both `xcodebuild`s, `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Mutation checks.** Revert the `lastError`/diagnostics guard: the failing-compile test must fail. Revert the `awaitIdle()`: the in-flight test must fail (if it does not, the debounce is too short to catch — raise `debounceInterval` in the test, not the code). Revert the `reload` cancel: its test fails. Record.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "fix(ui): record only the compiled document program; failures in the sheet; a recording dies with its window"
```

---

### Task 8: Clock sync, inspector drafts, shape-cache invalidation

Closes editor review findings 4, 8, 9, 10, 11, 12 (model half) and canvas H3 (model half), core finding 6 (apply).

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (`perform`: `.setSettings`, `.setParam`, `.restore`, the `shapesVersion` bump; `compileNow`'s shortcut; `lastCompiled`), `EditorModel+Recording.swift:37-43, 60-64`, `DocumentChange.swift`, `InspectorView.swift:216-245, 465-474`.
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorRecordingTests.swift` (`EditorClockSyncTests`), `ShapeCacheTests.swift`, `EditorModelTests.swift`.

**Interfaces:**
- Consumes: `Timeline.isValidDuration`, `ParamValue.finite` (Task 1), the Task 4 clock.
- Produces: `DocumentChange.changesShapes`.

- [ ] **Step 1: Write the failing tests**

`EditorClockSyncTests`:

```swift
@Test func aSettingsChangeThatLeavesTheClockAloneDoesNotRebaseIt() {
    let m = model()
    m.preview.clock.frame = 10
    m.preview.pausedElapsed = 0.123
    m.preview.playStartedAt = 42
    var s = m.document.settings
    s.exportName = "renamed"
    m.apply(.setSettings(s))
    #expect(m.preview.pausedElapsed == 0.123)
    #expect(m.preview.playStartedAt == 42)
    s.timeline.loops = false
    m.apply(.setSettings(s))
    #expect(m.preview.playStartedAt == nil)          // the timeline moved: re-based
}

@Test func playAtTheWallClockEndRestartsFromTheTop() {
    let m = model()
    var s = m.document.settings
    s.timeline = Timeline(duration: 1, frameRate: 60, loops: false)
    m.apply(.setSettings(s))
    m.preview.clock.seek(elapsed: 5)
    #expect(!m.preview.clock.isPlaying)
    m.togglePlayback()
    #expect(m.preview.clock.frame == 0)
    #expect(m.preview.clock.isPlaying)
    #expect(m.preview.pausedElapsed == 0)
}

@Test func setTimelineUsesTheSharedBound() {
    let m = model()
    m.setTimeline(Timeline(duration: 3600.5, frameRate: 60))
    #expect(m.document.settings.timeline.duration == 4)
    #expect(m.notice == "Duration must be between 0 and 3600 seconds")
}
```

`ShapeCacheTests`:

```swift
@Test func aCosmeticEditKeepsTheCache() {
    let m = model()
    _ = m.shapes
    let rebuilds = m.shapeCacheRebuilds
    let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
    m.apply(.moveNodes([uv.id: CGPoint(x: 10, y: 10)]))
    _ = m.shapes
    #expect(m.shapeCacheRebuilds == rebuilds)
    var s = m.document.settings
    s.exportName = "x"
    m.apply(.setSettings(s))
    _ = m.shapes
    #expect(m.shapeCacheRebuilds == rebuilds)
    m.apply(.setTitle(uv.id, "Renamed"))
    _ = m.shapes
    #expect(m.shapeCacheRebuilds == rebuilds + 1)
}

@Test func changesShapesPerCase() {
    let id = NodeID()
    #expect(!DocumentChange.moveNodes([id: .zero]).changesShapes)
    #expect(!DocumentChange.setParam(id, "scale", .float(2)).changesShapes)
    #expect(DocumentChange.setParam(id, "formula", .text("a")).changesShapes)
    #expect(DocumentChange.setParam(id, "op", .enumCase("add")).changesShapes)
    #expect(DocumentChange.setTitle(id, "t").changesShapes)
    #expect(DocumentChange.removeNodes([id]).changesShapes)
    #expect(DocumentChange.restore(ShaderDocument()).changesShapes)
}
```

`EditorModelTests`:

```swift
@Test func aNonFiniteParameterIsStoredAsZero() {
    let m = model()
    let node = m.document.root.nodes.values.first { $0.kind == .builtin("math.math") }!
    m.apply(.setParam(node.id, "b", .float(.nan)))
    #expect(m.document.root.nodes[node.id]?.params["b"] == .float(0))
    #expect(throws: Never.self) { try JSONEncoder().encode(m.document) }
}
```
Use a param name the node really has (read the Math node's inputs). And a `compileNow` test, if a failing double is available from Task 7: a model with a missing texture and a failing compiler shows both the error and the "is missing" warning; clearing `missingTextures` and scheduling a compile of the same source leaves the error and drops the warning. If staging a missing texture is more than ten lines, record the test as owed in the report and rely on the mutation check by reading.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "EditorClockSyncTests|ShapeCacheTests|EditorModelTests"`
Expected: `pausedElapsed` re-based; `togglePlayback` leaves frame 59; `changesShapes` missing; the NaN param survives.

- [ ] **Step 3: Implement**

`DocumentChange`:

```swift
/// Whether this change can alter any `NodeShape` (spec §27.9): a shape reads a node's kind, its
/// non-uniform params (an Expression's formula, a Math node's operator), its title, and its
/// definition's sockets and accent — never its position, the comments or the settings.
var changesShapes: Bool {
    switch self {
    case .moveNodes, .setSettings, .addSticky, .updateSticky, .addFrame, .updateFrame,
         .moveComments, .resizeComment, .removeComments: false
    case .setParam(_, _, let v): !v.isUniformable
    default: true
    }
}
```
`perform`:
- `.setParam(let id, let name, let value)` → apply `value.finite` (spec §27.2).
- `.setSettings(let s)`: compute `let clockMoved = s.timeline != document.settings.timeline || s.timeMode != document.settings.timeMode` before `document.settings = s`; `if clockMoved { syncClock() }`.
- `.restore(let doc)`: same comparison against the current settings before `document = doc`; `if clockMoved { syncClock() }`.
- the bump: `if change.changesShapes { shapesVersion += 1 }` — keep the comment about `.removeNodes` reading `shapes` before its edit.

`EditorModel+Recording`:

```swift
public func togglePlayback() {
    let c = preview.clock
    // Parked on the last frame with the loop off — in either mode (spec §27.5) — Play means
    // play the clip again from the top.
    if !c.isPlaying, !c.timeline.loops, c.frame == c.timeline.frameCount - 1 { resetPlayback() }
    preview.clock.isPlaying.toggle()
}

public func setTimeline(_ timeline: Timeline) {
    guard Timeline.isValidDuration(timeline.duration) else {
        showNotice("Duration must be between 0 and 3600 seconds")
        return
    }
    …
}
```
`compileNow`: `lastCompiled` gains `errors: [Diagnostic]` (the mapped compile errors, `[]` on success). The shortcut branch sets `diagnostics = last.errors + missing` unconditionally, keeping the `if last.succeeded` only around the uniform rebuild and `refreshTextureBindings()`. The success arm stores `errors: []`; the failure arm stores `errors: mapped.isEmpty ? [Diagnostic(.error, message)] : mapped`.

`InspectorView`: `@FocusState private var durationFocused: Bool`, `widthFocused`, `heightFocused`; on each of the three fields add `.focused($x)`, `.onChange(of: x) { _, focused in if !focused { commit… } }` and `.onDisappear { commit… }`, mirroring the export-name field exactly. `commitPreviewSize` is shared by W and H — calling it on either field's focus loss is correct (it reads both drafts).

- [ ] **Step 4: Run the tests** — the Step 2 command, `swift test`, both `xcodebuild`s, `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Mutation checks.** Revert the `clockMoved` guard, the `changesShapes` bump condition and `.finite` one at a time; each test fails. Record.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "fix(ui): sync the clock only when it moved; drafts commit on focus loss; cosmetic edits keep the shape cache"
```

---

### Task 9: Canvas hot paths

Closes canvas review findings H1, H2, M2 (and CommentLayer/DropResolver sorts).

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift:54, 100-107, 131, 189-197` and the Paste site that reads `hoverLocation` (grep), `NodeGeometry.swift:163-165`, `CommentLayer.swift:55, 61`, `DropResolver.swift:84`.
- Test: `MetalNodesKit/Tests/MetalNodesUITests/NodeGeometryTests.swift`.

- [ ] **Step 1: Write the failing test**

```swift
@Test func drawOrderByUUIDMatchesTheOldStringOrder() {
    let nodes = (0..<200).map { _ in NodeInstance(kind: .builtin("input.uv"), position: .zero) }
    let onTop: Set<NodeID> = Set(nodes.prefix(20).map(\.id))
    let byString = nodes.sorted {
        (onTop.contains($0.id) ? 1 : 0, $0.id.raw.uuidString) < (onTop.contains($1.id) ? 1 : 0, $1.id.raw.uuidString)
    }.map(\.id)
    let byKey = nodes.sorted { NodeGeometry.drawOrder($0, onTop: onTop) < NodeGeometry.drawOrder($1, onTop: onTop) }.map(\.id)
    #expect(byKey == byString)
    #expect(type(of: NodeGeometry.drawOrder(nodes[0], onTop: [])) == (Int, UUID).self)
}
```

- [ ] **Step 2: Run it** — `swift test --filter NodeGeometryTests`: the type assertion fails.

- [ ] **Step 3: Implement**

`NodeGeometry.drawOrder` returns `(Int, UUID)`: `(onTop.contains(node.id) ? 1 : 0, node.id.raw)`. `UUID` is `Comparable` (Foundation, macOS 14 / iOS 17) and its order is the byte order, which for uppercase `uuidString` equals the string order — say so in the doc comment. `CommentLayer.swift:55, 61` and `DropResolver.swift:84`: `$0.id.raw < $1.id.raw` (confirm `CommentID.raw` is a `UUID`; if a comment id is not, leave that sort alone and say so in the report).

`GraphCanvasView`:

```swift
/// A reference type on purpose: the hover point is read lazily (⇧A, the context menu, Paste),
/// and a `@State` value written on every pointer move would re-evaluate the whole canvas body —
/// every visible `NodeView` — per mouse event. Mutating a field of a class held in `@State`
/// invalidates nothing (spec §27.9).
final class PointBox { var point: CGPoint = .zero }
@State private var hover = PointBox()
```
`.onContinuousHover` writes `hover.point`; the three readers use `hover.point`. Wheel:

```swift
/// The wheel's camera write, once per gesture (spec §27.9): `viewState` is one observed value, so
/// writing it per tick re-evaluated the command tree, the inspector and the breadcrumb at wheel
/// rate. Drag, magnify and touch already write only on gesture end.
@State private var cameraWrite: Task<Void, Never>?

private func scheduleCameraWrite() {
    cameraWrite?.cancel()
    cameraWrite = Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        model.viewState.cameras[model.activePath] = transform.camera
    }
}
```
The catcher's closure calls `scheduleCameraWrite()` instead of writing `viewState`. Cancel the pending write in `.onDisappear` and wherever the view reacts to `model.activePath` changing (grep `onChange(of: model.activePath` — the camera for the new path is loaded there; a stale write must not land on it). Confirm `transform` inside the task reads the current `@State` value (it does: the closure captures `self`, a value whose `@State` reads go to storage).

- [ ] **Step 4: Run the tests** — `swift test --filter "NodeGeometryTests|CanvasTransformTests|DropResolverTests|EditorCommentsTests"`, then `swift test`, both `xcodebuild`s, `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Mutation check.** Return `(Int, String)` again from `drawOrder`; the type assertion fails. Record. The wheel and hover changes have no unit test (SwiftUI) — say so in the report; Task 11's live checks cover them.

- [ ] **Step 6: Commit**

```bash
git commit -am "perf(canvas): camera written once per wheel gesture; hover unobserved; UUID sorts"
```

---

### Task 10: Transaction ownership and gesture state

Closes canvas review findings H4, L3, M8 and editor finding 5.

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel+Undo.swift`, `Canvas/ParamControl.swift:19-27, 55-105`, `Canvas/GraphCanvasView.swift:162-165, 185-188, 359, 387, 473, 530, 584, 590`.
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorUndoTests.swift`.

**Interfaces:**
- Produces: `EditorModel.endAllTransactions()`, `EditorModel.cancelAllTransactions()`.

- [ ] **Step 1: Write the failing tests**

```swift
@Test func endAllTransactionsUnwindsEveryLevelIntoOneStep() {
    let m = model()
    let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
    m.beginTransaction("Move")
    m.beginTransaction("Move")
    m.beginTransaction("Move")
    m.apply(.moveNodes([uv.id: CGPoint(x: 5, y: 5)]))
    m.endAllTransactions()
    #expect(!m.isInTransaction)
    #expect(m.canUndo)
    #expect(m.undoManager.undoActionName == "Move")
    m.undo()
    #expect(m.document.root.nodes[uv.id]?.position == uv.position)
    #expect(!m.canUndo)                                 // exactly one step was registered
}

@Test func cancelAllTransactionsRestoresTheSnapshotFromAnyDepth() {
    let m = model()
    let uv = m.document.root.nodes.values.first { $0.kind == .builtin("input.uv") }!
    m.beginTransaction("Rewire")
    m.beginTransaction("Rewire")
    m.apply(.moveNodes([uv.id: CGPoint(x: 5, y: 5)]))
    m.cancelAllTransactions()
    #expect(!m.isInTransaction)
    #expect(m.document.root.nodes[uv.id]?.position == uv.position)
    #expect(!m.canUndo)
}
```
Use the file's own `model()` helper and its undo-manager access (`m.undoManager` may be `private(set)`, which is readable).

- [ ] **Step 2: Run them** — `swift test --filter EditorUndoTests`: no such members.

- [ ] **Step 3: Implement**

`EditorModel+Undo`:

```swift
/// Closes every open level. The canvas's reset before a new gesture (spec §27.9): a stranded
/// transaction — a drag SwiftUI cancelled without `onEnded` — is committed as the step it was
/// named for, never silently nested under the gesture that found it.
public func endAllTransactions() { while transactionDepth > 0 { endTransaction() } }

/// Abandons every open level; the document goes back to the outermost snapshot.
public func cancelAllTransactions() { while transactionDepth > 0 { cancelTransaction() } }
```
`ParamControl` text field: remove `editingSession` and every `onEditing?(…)` call on the text path. The field keeps `.onSubmit { commitDraft() }`, `.onChange(of: focused) { _, now in if !now { commitDraft() } }` and `.onDisappear { commitDraft() }`. Replace the two long comments with one: a text field holds no transaction — its single `apply` is its own undo step, so nothing can be stranded by a teardown and nothing unrelated can be absorbed while it is focused (spec §27.9). The slider path (`onEditingChanged: { onEditing?($0) }`) is unchanged.

`GraphCanvasView`:

```swift
/// Before any gesture opens its own transaction (spec §27.9). A wire drag that was cancelled
/// without `onEnded` has applied a `.disconnect` it never resolved: that one is rolled back,
/// like Escape does. Any other stranded transaction is committed under its own name.
private func resetStrandedGesture() {
    if pendingWire != nil {
        pendingWire = nil
        model.cancelAllTransactions()
    } else {
        model.endAllTransactions()
    }
}
```
Each `if model.isInTransaction { model.endTransaction() }   // defensive reset…` site (lines 387, 473, 530, 584, 590) becomes `resetStrandedGesture()`. Line 359: `let compact = pendingWire == nil && transform.zoom < Self.lodZoom` with a comment: the socket that owns a live drag lives in the standard body; flipping to compact mid-drag tears it down and SwiftUI cancels the gesture without `onEnded`. Space:

```swift
.onKeyPress(.space, phases: [.down, .repeat, .up]) { press in
    spaceHeld = press.phase != .up          // `.repeat` is still held
    return .handled
}
```
and on macOS, `@Environment(\.controlActiveState) private var controlActiveState` with `.onChange(of: controlActiveState) { _, s in if s != .key { spaceHeld = false } }` inside `#if os(macOS)` (an app switch with Space down never delivers the `.up`).

- [ ] **Step 4: Run the tests** — `swift test --filter "EditorUndoTests|ExpressionEditorTests|EditorModelTests"`, `swift test`, both `xcodebuild`s, `git checkout -- MetalNodes.xcodeproj/project.pbxproj`.

- [ ] **Step 5: Mutation check.** Make `endAllTransactions` call `endTransaction()` once; the depth-3 test fails. Record. The `ParamControl`, LOD and Space changes are live-checked in Task 11.

- [ ] **Step 6: Commit**

```bash
git commit -am "fix(canvas): text fields hold no transaction; stranded gestures unwind fully; LOD frozen during a wire drag; Space cannot latch"
```

---

### Task 11: Live checks and the execution record (controller)

- [ ] **Step 1: Build the app** with the macOS `xcodebuild` into a scratch DerivedData directory and launch it with `open -n`; verify the running binary is the one built (`ps -o command -p $(pgrep -x MetalNodes)`).

- [ ] **Step 2: Run the §27.11 live list** with the screen unlocked, using the terminal-driven method from the M10 handoff (screencapture + cliclick + System Events `keystroke`):
  1. ⇧A, type `fp,.`: all four characters in the chooser field; no zoom or playback change. **If it fails:** gate the bare-key items in `EditorCommands` additionally on `!(NSApp.keyWindow?.firstResponder is NSText)` (the `textViewIsFirstResponder` test Undo already uses) and re-run.
  2. Expression node with `fmod(a, 2.0)`: one socket `a`, preview compiles.
  3. Fixed rate, 24 fps, 4 s: the counter reaches 96 in ~4 s of wall time.
  4. Duration: type `2.5`, click the canvas: the caption reads 150 frames and the document holds 2.5 (Export Video's sheet says 2.5 s).
  5. Custom Code node with `out = nosuch(in_a);` wired to the output; File ▸ Export Video… ▸ Record: the sheet shows "Export failed — The graph has errors…" with an OK button.
  6. Wheel-pan with the inspector open: no flicker of the inspector; camera restored after ⌘W/reopen.
  7. Set the export size to 8192 × 8192 for a video: the sheet refuses with the H.264 text; 8192 × 4352 records.
- [ ] **Step 3: Write handoff §18** (`docs/superpowers/specs/2026-09-04-metalnodes-handoff.md`): shipped table by task with commits; rulings; live-check results; what the reviews caught; the M12 list from spec §27.10 plus anything parked in the ledger.
- [ ] **Step 4: Commit the docs**, run the full package suite and both `xcodebuild`s one last time, then hand over to `superpowers:finishing-a-development-branch`.
