# MetalNodes M0+M1 — Foundation and First Pixels — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the empty Xcode template into a macOS app that loads a built-in node graph, generates Metal Shading Language from it, compiles it at runtime, renders it live in a preview panel, and updates the preview at frame rate when a node parameter slider moves — without recompiling.

**Architecture:** A local Swift package `MetalNodesKit` with three targets. `MetalNodesCore` is pure value types: the document model, a data-driven node registry, and a code generator that emits SSA-style MSL plus a uniform-buffer layout. `MetalNodesRender` owns the Metal device, an actor that compiles generated source into pipelines with a latest-wins generation counter, and an `MTKView` renderer. `MetalNodesUI` is SwiftUI: Dracula theme tokens, a pan/zoom canvas that draws nodes and wires, and an `EditorModel` that classifies every document change as cosmetic / parameter / topology and drives the compiler accordingly.

**Tech Stack:** Swift 6.4, SwiftUI, Metal, MetalKit, Swift Testing, SwiftPM local package inside an Xcode 27 project.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — the plan argues from the spec; read both. This plan implements milestones **M0** and **M1** (spec §15). Groups (M4), comments (M5), the viewer flag (M3), palette and connection editing (M2), persistence (M5) and iPad (M6) are deliberately **not** in this plan, but every type they need is shaped so they can be added without changing what this plan builds.

## Global Constraints

- Swift language mode `6`, strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete` in the package via `swiftLanguageMode(.v6)`).
- Default actor isolation `MainActor` is on in the app target; package targets opt in per-target (see Task 2).
- `MetalNodesCore` imports only `Foundation` and `CoreGraphics`. **No AppKit, no UIKit, no Metal.**
- `MetalNodesRender` imports `Metal`, `MetalKit`, `MetalNodesCore`. No SwiftUI except the `PreviewView` representable file.
- Platforms: `macOS 26`, `iPadOS 27`. `SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator"`, `TARGETED_DEVICE_FAMILY = "2"` (iPad only, no iPhone). This plan builds and runs on macOS; the iPad UI layer is M6, but nothing here may break the iPad build.
- Deployment targets: `MACOSX_DEPLOYMENT_TARGET = 26.0`, `IPHONEOS_DEPLOYMENT_TARGET = 27.0`.
- Bundle identifier: `com.maxburger.MetalNodes`.
- Colors only through `DraculaTheme` tokens. No hex literals outside `DraculaTheme.swift`.
- Sockets are addressed by **name**, never index. Edges are stored `input → output` in a dictionary.
- Every uniform slot is sorted by alignment (16, 8, 4) and `float3` is 16 bytes.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). Never XCTest.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- Run package tests with `swift test --package-path MetalNodesKit`. Run the app build with `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build`.

---

## File structure

```
.gitignore
MetalNodes.xcodeproj/project.pbxproj          modify — retarget, link package
MetalNodes/
  MetalNodesApp.swift                          rename from MyApp.swift; hosts EditorView
  ContentView.swift                            delete
MetalNodesKit/
  Package.swift
  Sources/
    MetalNodesCore/
      Identifiers.swift        NodeID, GroupID, StickyID, FrameID, AssetID, ParamID
      SocketType.swift         SocketType, TypeRef — MSL names, sizes, alignment
      Conversion.swift         ConversionRules.convert(from:to:) → Conversion
      ParamValue.swift         ParamValue, SocketDefault
      NodeDef.swift            NodeDef, SocketDecl, ParamDecl, ParamKind, NodeBody, NodeCategory
      NodeRegistry.swift       NodeRegistry — lookup + validation of definitions
      Graph.swift              Graph, NodeInstance, NodeKind, SocketRef, StickyNote, CommentFrame
      ShaderDocument.swift     ShaderDocument, GroupDefinition, DocumentSettings
      EditorViewState.swift    EditorViewState, Camera, GraphPath
      Library/MSLStdlib.swift  named MSL helper functions with dependencies
      Library/BuiltinNodes.swift  the M1 node set as NodeDef values
      Library/SampleDocuments.swift  ShaderDocument.sample — the graph the app opens with
      Codegen/Diagnostic.swift       Diagnostic, GenerationError
      Codegen/Validation.swift       GraphValidator — cycles, terminal, kinds, required inputs
      Codegen/TypeResolver.swift     TypeResolver — resolves generics per instance
      Codegen/TopoSort.swift         TopoSort.order(reachableFrom:)
      Codegen/UniformLayout.swift    ParamPath, UniformLayout, UniformLayoutBuilder
      Codegen/LineMap.swift          LineMap
      Codegen/Emitter.swift          Emitter — SSA statements from templates
      Codegen/ShaderGenerator.swift  ShaderGenerator.generate(_:target:registry:) → GeneratedShader
    MetalNodesRender/
      VertexStage.swift        static fullscreen-triangle vertex source + VertexOut struct
      ShaderCompiler.swift     actor — compile, cache by source hash, generation counter
      UniformImage.swift       CPU-side byte image built from layout + values
      UniformRing.swift        triple-buffered MTLBuffer ring
      ShaderRenderer.swift     MTKViewDelegate — draws the fullscreen triangle
      PreviewState.swift       @Observable hand-off object between UI and renderer
      PreviewView.swift        NSViewRepresentable / UIViewRepresentable around MTKView
    MetalNodesUI/
      Theme/DraculaTheme.swift        every color token; category and socket color maps
      Canvas/CanvasTransform.swift    pan/zoom math, screen↔canvas conversion
      Canvas/WireLayer.swift          Canvas drawing Bézier wires
      Canvas/SocketView.swift         one socket dot/diamond/square
      Canvas/NodeView.swift           node body: header, sockets, parameter controls
      Canvas/GraphCanvasView.swift    ZStack of NodeViews over WireLayer, gestures
      Editor/DocumentChange.swift     DocumentChange enum + ChangeClass
      Editor/EditorModel.swift        @Observable — owns document, applies changes, drives compile
      Editor/EditorView.swift         HSplitView: canvas | preview + diagnostics strip
  Tests/
    MetalNodesCoreTests/
      SocketTypeTests.swift
      ConversionTests.swift
      NodeRegistryTests.swift
      GraphCodableTests.swift
      ValidationTests.swift
      TypeResolverTests.swift
      TopoSortTests.swift
      UniformLayoutTests.swift
      ShaderGeneratorTests.swift
      Fixtures/GraphFixtures.swift
    MetalNodesRenderTests/
      ShaderCompilerTests.swift
      UniformImageTests.swift
    MetalNodesUITests/
      CanvasTransformTests.swift
      EditorModelTests.swift
```

---

### Task 1: Repository hygiene and project retarget

**Files:**
- Create: `.gitignore`
- Modify: `MetalNodes.xcodeproj/project.pbxproj`
- Rename: `MetalNodes/MyApp.swift` → `MetalNodes/MetalNodesApp.swift`
- Modify: `MetalNodes/ContentView.swift`

**Interfaces:**
- Produces: an Xcode project that builds for macOS only with the settings in Global Constraints; the initial git commit.

- [ ] **Step 1: Verify `.gitignore`**

`.gitignore` already exists from the initial commit and must **not** be rewritten (it also ignores `.superpowers/`, the executor's scratch directory). Verify it contains at least these entries and add any that are missing:

```gitignore
# macOS
.DS_Store

# Xcode
xcuserdata/
*.xcuserstate
DerivedData/
*.xcscmblueprint
*.xccheckout

# SwiftPM
.build/
.swiftpm/
Package.resolved

# Scratch
*.orig
```

- [ ] **Step 2: Retarget the project with a scripted edit**

Run from the repo root:

```bash
python3 - <<'PY'
import re, io
p = 'MetalNodes.xcodeproj/project.pbxproj'
s = io.open(p, encoding='utf-8').read()
subs = [
  ('SUPPORTED_PLATFORMS = "iphoneos iphonesimulator macosx xros xrsimulator";',
   'SUPPORTED_PLATFORMS = "macosx iphoneos iphonesimulator";'),
  ('TARGETED_DEVICE_FAMILY = "1,2,7";', 'TARGETED_DEVICE_FAMILY = "2";'),
  ('SWIFT_VERSION = 5.0;', 'SWIFT_VERSION = 6.0;'),
  ('MACOSX_DEPLOYMENT_TARGET = 26.6.2;', 'MACOSX_DEPLOYMENT_TARGET = 26.0;'),
  ('PRODUCT_BUNDLE_IDENTIFIER = "devplaceholder.$(PROJECT_UNIQUE_VALUE:identifier).$(PRODUCT_NAME:rfc1034identifier)";',
   'PRODUCT_BUNDLE_IDENTIFIER = com.maxburger.MetalNodes;'),
  ('productName = MyApp;', 'productName = MetalNodes;'),
]
for old, new in subs:
    c = s.count(old)
    assert c >= 1, old
    s = s.replace(old, new)
    print(f'{c}x  {old[:50]}')
# strict concurrency in the app target (both configurations)
s = s.replace('SWIFT_VERSION = 6.0;', 'SWIFT_STRICT_CONCURRENCY = complete;\n\t\t\t\tSWIFT_VERSION = 6.0;')
io.open(p, 'w', encoding='utf-8').write(s)
PY
```

Expected output: six lines — five starting with `2x` (Debug and Release) and `productName` with `1x`.

- [ ] **Step 3: Rename the app file and strip the playground**

```bash
git mv -f MetalNodes/MyApp.swift MetalNodes/MetalNodesApp.swift 2>/dev/null || mv MetalNodes/MyApp.swift MetalNodes/MetalNodesApp.swift
cat > MetalNodes/MetalNodesApp.swift <<'SWIFT'
import SwiftUI

@main
struct MetalNodesApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
SWIFT
cat > MetalNodes/ContentView.swift <<'SWIFT'
import SwiftUI

struct ContentView: View {
    var body: some View {
        Text("MetalNodes")
            .padding()
    }
}
SWIFT
```

- [ ] **Step 4: Verify the app builds for macOS**

Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

If `xcodebuild` reports the scheme is not found, run `xcodebuild -project MetalNodes.xcodeproj -list` and use the target form instead: `xcodebuild -project MetalNodes.xcodeproj -target MetalNodes -sdk macosx build`.

- [ ] **Step 5: Commit**

```bash
git add .gitignore MetalNodes.xcodeproj/project.pbxproj MetalNodes
git commit -m "chore: retarget template to macOS + iPadOS, Swift 6

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 2: MetalNodesKit package skeleton, linked into the app

**Files:**
- Create: `MetalNodesKit/Package.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Identifiers.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/Placeholder.swift` (deleted in Task 13)
- Create: `MetalNodesKit/Sources/MetalNodesUI/Placeholder.swift` (deleted in Task 15)
- Create: `MetalNodesKit/Tests/MetalNodesCoreTests/IdentifierTests.swift`
- Modify: `MetalNodes.xcodeproj/project.pbxproj`
- Modify: `MetalNodes/ContentView.swift`

**Interfaces:**
- Produces: `NodeID`, `GroupID`, `StickyID`, `FrameID`, `AssetID` — `struct X: Hashable, Codable, Sendable { let raw: UUID; init(); init(raw: UUID) }`; `typealias ParamID = String`. Three importable modules. The app links `MetalNodesUI`.

- [ ] **Step 1: Write the failing test**

`MetalNodesKit/Tests/MetalNodesCoreTests/IdentifierTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct IdentifierTests {
    @Test func freshIDsAreDistinct() {
        #expect(NodeID() != NodeID())
    }

    @Test func idRoundTripsThroughJSONAsBareString() throws {
        let id = NodeID(raw: UUID(uuidString: "00000000-0000-0000-0000-000000000042")!)
        let data = try JSONEncoder().encode(id)
        #expect(String(data: data, encoding: .utf8) == "\"00000000-0000-0000-0000-000000000042\"")
        #expect(try JSONDecoder().decode(NodeID.self, from: data) == id)
    }
}
```

- [ ] **Step 2: Write `Package.swift`**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MetalNodesKit",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "MetalNodesCore", targets: ["MetalNodesCore"]),
        .library(name: "MetalNodesRender", targets: ["MetalNodesRender"]),
        .library(name: "MetalNodesUI", targets: ["MetalNodesUI"]),
    ],
    targets: [
        .target(
            name: "MetalNodesCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetalNodesRender",
            dependencies: ["MetalNodesCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MetalNodesUI",
            dependencies: ["MetalNodesCore", "MetalNodesRender"],
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
        ),
        .testTarget(name: "MetalNodesCoreTests", dependencies: ["MetalNodesCore"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MetalNodesRenderTests", dependencies: ["MetalNodesRender"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "MetalNodesUITests", dependencies: ["MetalNodesUI"],
                    swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
```

If `swift build` rejects `.macOS(.v26)` / `.iOS(.v27)` with the installed tools, use `.macOS("26.0"), .iOS("27.0")` string forms instead.

- [ ] **Step 3: Write `Identifiers.swift` and the two placeholder files**

`MetalNodesKit/Sources/MetalNodesCore/Identifiers.swift`:

```swift
import Foundation

/// Strongly-typed UUID wrappers. Each encodes as a bare UUID string so the
/// JSON stays readable and the types can never be mixed up at compile time.
public protocol EntityID: Hashable, Codable, Sendable, CustomStringConvertible {
    var raw: UUID { get }
    init(raw: UUID)
}

public extension EntityID {
    init() { self.init(raw: UUID()) }
    init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(UUID.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }
    var description: String { raw.uuidString }
}

public struct NodeID: EntityID   { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct GroupID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct StickyID: EntityID { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct FrameID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }
public struct AssetID: EntityID  { public let raw: UUID; public init(raw: UUID) { self.raw = raw } }

/// Parameter and socket-value keys on a node instance. Socket names and
/// parameter names share one namespace per node definition (Task 5 enforces uniqueness).
public typealias ParamID = String
```

`MetalNodesKit/Sources/MetalNodesRender/Placeholder.swift`:

```swift
import MetalNodesCore
public enum MetalNodesRenderPlaceholder {}
```

`MetalNodesKit/Sources/MetalNodesUI/Placeholder.swift`:

```swift
import SwiftUI
import MetalNodesCore

public struct EditorView: View {
    public init() {}
    public var body: some View { Text("MetalNodesUI linked") }
}
```

Create empty test files so the other two test targets have at least one source: `MetalNodesKit/Tests/MetalNodesRenderTests/Placeholder.swift` and `MetalNodesKit/Tests/MetalNodesUITests/Placeholder.swift` each containing `import Testing`.

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test --package-path MetalNodesKit 2>&1 | tail -5`
Expected: `Test run with 2 tests … passed` (exact wording varies by toolchain; all tests pass, zero failures).

- [ ] **Step 5: Link the package into the Xcode project**

```bash
python3 - <<'PY'
import io
p = 'MetalNodes.xcodeproj/project.pbxproj'
s = io.open(p, encoding='utf-8').read()

def ins(anchor, text, before=False):
    global s
    assert s.count(anchor) == 1, anchor
    s = s.replace(anchor, (text + anchor) if before else (anchor + text))

# 1. build file in Frameworks phase
ins('/* Begin PBXFileReference section */',
    '/* Begin PBXBuildFile section */\n'
    '\t\tAA00000000000000000000A1 /* MetalNodesUI in Frameworks */ = {isa = PBXBuildFile; productRef = AA00000000000000000000B1 /* MetalNodesUI */; };\n'
    '/* End PBXBuildFile section */\n\n', before=True)
ins('\t\t000000000000000130000000 /* Frameworks */ = {\n\t\t\tisa = PBXFrameworksBuildPhase;\n\t\t\tfiles = (\n',
    '\t\t\t\tAA00000000000000000000A1 /* MetalNodesUI in Frameworks */,\n')
# 2. product dependency on the target
ins('\t\t\tname = MetalNodes;\n\t\t\tproductName = MetalNodes;\n',
    '\t\t\tpackageProductDependencies = (\n\t\t\t\tAA00000000000000000000B1 /* MetalNodesUI */,\n\t\t\t);\n', before=True)
# 3. package reference on the project
ins('\t\t\tminimizedProjectReferenceProxies = 1;\n',
    '\t\t\tpackageReferences = (\n\t\t\t\tAA00000000000000000000C1 /* XCLocalSwiftPackageReference "MetalNodesKit" */,\n\t\t\t);\n')
# 4. the two new object sections
ins('/* End XCConfigurationList section */\n',
    '\n/* Begin XCLocalSwiftPackageReference section */\n'
    '\t\tAA00000000000000000000C1 /* XCLocalSwiftPackageReference "MetalNodesKit" */ = {\n'
    '\t\t\tisa = XCLocalSwiftPackageReference;\n\t\t\trelativePath = MetalNodesKit;\n\t\t};\n'
    '/* End XCLocalSwiftPackageReference section */\n\n'
    '/* Begin XCSwiftPackageProductDependency section */\n'
    '\t\tAA00000000000000000000B1 /* MetalNodesUI */ = {\n'
    '\t\t\tisa = XCSwiftPackageProductDependency;\n\t\t\tproductName = MetalNodesUI;\n\t\t};\n'
    '/* End XCSwiftPackageProductDependency section */\n')
io.open(p, 'w', encoding='utf-8').write(s)
print('linked')
PY
```

Then make the app use it — `MetalNodes/ContentView.swift`:

```swift
import SwiftUI
import MetalNodesUI

struct ContentView: View {
    var body: some View {
        EditorView()
    }
}
```

- [ ] **Step 6: Verify the app builds against the package**

Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error|BUILD' | head`
Expected: `** BUILD SUCCEEDED **` and no `error:` lines. If Xcode complains the package cannot be resolved, open the project once in Xcode (File ▸ Packages ▸ Resolve Package Versions) and re-run.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit MetalNodes.xcodeproj/project.pbxproj MetalNodes/ContentView.swift
git commit -m "feat: add MetalNodesKit package (Core/Render/UI) and link into app

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 3: SocketType and TypeRef

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/SocketType.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/SocketTypeTests.swift`

**Interfaces:**
- Produces: `enum SocketType: String, Codable, Sendable, CaseIterable, Hashable` with cases `float, float2, float3, float4, color, int, bool, texture` and properties `mslName: String`, `uniformStorageName: String?`, `byteSize: Int?`, `alignment: Int?`, `componentCount: Int?`, `isUniformable: Bool`. `enum TypeRef: Hashable, Sendable, Codable { case concrete(SocketType), generic(String) }`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct SocketTypeTests {
    @Test func mslNames() {
        #expect(SocketType.float.mslName == "float")
        #expect(SocketType.color.mslName == "float4")
        #expect(SocketType.texture.mslName == "texture2d<float>")
    }

    @Test func float3IsSixteenBytes() {
        #expect(SocketType.float3.byteSize == 16)
        #expect(SocketType.float3.alignment == 16)
    }

    @Test(arguments: [
        (SocketType.float, 4, 4), (.float2, 8, 8), (.float3, 16, 16), (.float4, 16, 16),
        (.color, 16, 16), (.int, 4, 4), (.bool, 4, 4),
    ])
    func sizeAndAlignment(type: SocketType, size: Int, alignment: Int) {
        #expect(type.byteSize == size)
        #expect(type.alignment == alignment)
    }

    @Test func boolIsStoredAsIntInUniforms() {
        #expect(SocketType.bool.uniformStorageName == "int")
    }

    @Test func textureIsNotUniformable() {
        #expect(SocketType.texture.isUniformable == false)
        #expect(SocketType.texture.byteSize == nil)
        #expect(SocketType.texture.uniformStorageName == nil)
    }

    @Test func componentCounts() {
        #expect(SocketType.float.componentCount == 1)
        #expect(SocketType.color.componentCount == 4)
        #expect(SocketType.texture.componentCount == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter SocketTypeTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'SocketType' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The type carried by a socket. `color` is a `float4` with a semantic tag —
/// it draws differently and converts to `float` by luminance rather than average.
public enum SocketType: String, Codable, Sendable, CaseIterable, Hashable {
    case float, float2, float3, float4, color, int, bool, texture

    /// The MSL spelling of this type in expressions and local variables.
    public var mslName: String {
        switch self {
        case .float: "float"
        case .float2: "float2"
        case .float3: "float3"
        case .float4, .color: "float4"
        case .int: "int"
        case .bool: "bool"
        case .texture: "texture2d<float>"
        }
    }

    /// The MSL type used when this value lives in the `Uniforms` struct.
    /// `bool` is one byte in MSL, so it is stored as `int` and cast on read.
    public var uniformStorageName: String? {
        switch self {
        case .texture: nil
        case .bool: "int"
        default: mslName
        }
    }

    /// Size in bytes inside a `constant` buffer. **`float3` is 16, not 12.**
    public var byteSize: Int? {
        switch self {
        case .float, .int, .bool: 4
        case .float2: 8
        case .float3, .float4, .color: 16
        case .texture: nil
        }
    }

    /// Alignment in bytes inside a `constant` buffer — identical to size for every scalar and vector type.
    public var alignment: Int? { byteSize }

    public var componentCount: Int? {
        switch self {
        case .float, .int, .bool: 1
        case .float2: 2
        case .float3: 3
        case .float4, .color: 4
        case .texture: nil
        }
    }

    public var isUniformable: Bool { self != .texture }

    public var isVector: Bool {
        switch self {
        case .float2, .float3, .float4, .color: true
        default: false
        }
    }
}

/// A socket's declared type: concrete, or a generic parameter resolved per node instance.
public enum TypeRef: Hashable, Sendable, Codable {
    case concrete(SocketType)
    case generic(String)
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter SocketTypeTests 2>&1 | tail -3`
Expected: all SocketTypeTests pass.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): SocketType with MSL names, sizes and alignment

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 4: Implicit conversion rules

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Conversion.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ConversionTests.swift`

**Interfaces:**
- Consumes: `SocketType`.
- Produces: `struct Conversion: Sendable, Equatable { let from: SocketType; let to: SocketType; var isIdentity: Bool; func apply(_ expr: String) -> String }` and `enum ConversionRules { static func convert(from: SocketType, to: SocketType) -> Conversion? }`. `nil` means the connection is rejected.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ConversionTests {
    private func msl(_ from: SocketType, _ to: SocketType, _ e: String = "v") -> String? {
        ConversionRules.convert(from: from, to: to)?.apply(e)
    }

    @Test func identityIsPassThrough() {
        let c = ConversionRules.convert(from: .float3, to: .float3)
        #expect(c?.isIdentity == true)
        #expect(c?.apply("v") == "v")
    }

    @Test func colorAndFloat4AreFreelyInterchangeable() {
        #expect(ConversionRules.convert(from: .color, to: .float4)?.isIdentity == true)
        #expect(ConversionRules.convert(from: .float4, to: .color)?.isIdentity == true)
    }

    @Test func scalarSplatsToVectors() {
        #expect(msl(.float, .float2) == "float2(v)")
        #expect(msl(.float, .float3) == "float3(v)")
        #expect(msl(.float, .float4) == "float4(v)")
        #expect(msl(.float, .color) == "float4(float3(v), 1.0)")
    }

    @Test func vectorsWiden() {
        #expect(msl(.float2, .float3) == "float3(v, 0.0)")
        #expect(msl(.float2, .float4) == "float4(v, 0.0, 1.0)")
        #expect(msl(.float3, .float4) == "float4(v, 1.0)")
        #expect(msl(.float3, .color) == "float4(v, 1.0)")
    }

    @Test func vectorsTruncate() {
        #expect(msl(.float4, .float3) == "(v).xyz")
        #expect(msl(.color, .float3) == "(v).xyz")
        #expect(msl(.float3, .float2) == "(v).xy")
        #expect(msl(.float4, .float2) == "(v).xy")
    }

    @Test func vectorToFloatIsAverageButColorIsLuminance() {
        #expect(msl(.float2, .float) == "dot(v, float2(0.5))")
        #expect(msl(.float3, .float) == "dot(v, float3(1.0 / 3.0))")
        #expect(msl(.float4, .float) == "dot(v, float4(0.25))")
        #expect(msl(.color, .float) == "dot((v).rgb, float3(0.2126, 0.7152, 0.0722))")
    }

    @Test func scalarsCastAmongThemselves() {
        #expect(msl(.int, .float) == "float(v)")
        #expect(msl(.float, .int) == "int(v)")
        #expect(msl(.bool, .float) == "(v ? 1.0 : 0.0)")
        #expect(msl(.bool, .int) == "int(v)")
        #expect(msl(.float, .bool) == "(v != 0.0)")
        #expect(msl(.int, .bool) == "(v != 0)")
    }

    @Test func intAndBoolReachVectorsThroughFloat() {
        #expect(msl(.int, .float3) == "float3(float(v))")
        #expect(msl(.bool, .float2) == "float2((v ? 1.0 : 0.0))")
    }

    @Test func vectorsReachIntAndBoolThroughFloat() {
        #expect(msl(.float3, .int) == "int(dot(v, float3(1.0 / 3.0)))")
        #expect(msl(.float2, .bool) == "(dot(v, float2(0.5)) != 0.0)")
    }

    @Test(arguments: SocketType.allCases)
    func textureConvertsToAndFromNothing(other: SocketType) {
        if other == .texture {
            #expect(ConversionRules.convert(from: .texture, to: .texture)?.isIdentity == true)
        } else {
            #expect(ConversionRules.convert(from: .texture, to: other) == nil)
            #expect(ConversionRules.convert(from: other, to: .texture) == nil)
        }
    }

    @Test func everyNonTexturePairIsConvertible() {
        for a in SocketType.allCases where a != .texture {
            for b in SocketType.allCases where b != .texture {
                #expect(ConversionRules.convert(from: a, to: b) != nil, "\(a) → \(b)")
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ConversionTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'ConversionRules' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// An implicit conversion inserted by codegen where a wire joins two sockets of
/// different types. `apply` wraps an MSL expression. See spec §7.2.
public struct Conversion: Sendable, Equatable {
    public let from: SocketType
    public let to: SocketType

    public var isIdentity: Bool {
        from == to || Set([from, to]) == Set([.color, .float4])
    }

    public func apply(_ expr: String) -> String {
        if isIdentity { return expr }
        // Route every scalar-ish source through `float`, then widen.
        if to.isVector {
            let asFloat: String
            switch from {
            case .int: asFloat = "float(\(expr))"
            case .bool: asFloat = "(\(expr) ? 1.0 : 0.0)"
            case .float: asFloat = expr
            default: return Conversion.vectorToVector(from: from, to: to, expr)
            }
            return Conversion.scalarToVector(to: to, asFloat)
        }
        // Destination is scalar (float / int / bool).
        let asFloat: String
        switch from {
        case .float: asFloat = expr
        case .int:
            if to == .float { return "float(\(expr))" }
            if to == .bool { return "(\(expr) != 0)" }
            asFloat = "float(\(expr))"
        case .bool:
            if to == .float { return "(\(expr) ? 1.0 : 0.0)" }
            if to == .int { return "int(\(expr))" }
            asFloat = expr
        case .float2: asFloat = "dot(\(expr), float2(0.5))"
        case .float3: asFloat = "dot(\(expr), float3(1.0 / 3.0))"
        case .float4: asFloat = "dot(\(expr), float4(0.25))"
        case .color:  asFloat = "dot((\(expr)).rgb, float3(0.2126, 0.7152, 0.0722))"
        case .texture: return expr // unreachable: convert(from:to:) refuses textures
        }
        switch to {
        case .float: return asFloat
        case .int: return "int(\(asFloat))"
        case .bool: return "(\(asFloat) != 0.0)"
        default: return asFloat // unreachable
        }
    }

    private static func scalarToVector(to: SocketType, _ f: String) -> String {
        switch to {
        case .float2: "float2(\(f))"
        case .float3: "float3(\(f))"
        case .float4: "float4(\(f))"
        case .color:  "float4(float3(\(f)), 1.0)"
        default: f
        }
    }

    private static func vectorToVector(from: SocketType, to: SocketType, _ e: String) -> String {
        let n = from.componentCount ?? 0
        let m = to.componentCount ?? 0
        if m < n {
            return m == 3 ? "(\(e)).xyz" : "(\(e)).xy"
        }
        switch (from, to) {
        case (.float2, .float3): return "float3(\(e), 0.0)"
        case (.float2, .float4), (.float2, .color): return "float4(\(e), 0.0, 1.0)"
        case (.float3, .float4), (.float3, .color): return "float4(\(e), 1.0)"
        default: return e
        }
    }
}

public enum ConversionRules {
    /// `nil` means the two types may not be connected.
    public static func convert(from: SocketType, to: SocketType) -> Conversion? {
        switch (from, to) {
        case (.texture, .texture): Conversion(from: from, to: to)
        case (.texture, _), (_, .texture): nil
        default: Conversion(from: from, to: to)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter ConversionTests 2>&1 | tail -3`
Expected: all ConversionTests pass.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): implicit socket conversion rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 5: ParamValue, NodeDef and NodeRegistry

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/ParamValue.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/NodeRegistry.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/NodeRegistryTests.swift`

**Interfaces:**
- Consumes: `SocketType`, `TypeRef`, `AssetID`.
- Produces:
  - `enum ParamValue: Codable, Sendable, Hashable { case float(Float), float2(SIMD2<Float>), float3(SIMD3<Float>), float4(SIMD4<Float>), int(Int32), bool(Bool), enumCase(String), asset(AssetID?) }` with `var socketType: SocketType?` (nil for `enumCase`/`asset`) and `var mslLiteral: String`.
  - `enum SocketDefault: Sendable, Hashable, Codable { case required, value(ParamValue), uv }`
  - `struct SocketDecl: Sendable, Hashable, Codable { name, label, type: TypeRef, default: SocketDefault }`
  - `enum ParamKind: Sendable, Hashable { case value(SocketType, range: ClosedRange<Float>?), enumeration([String]), asset }`
  - `struct ParamDecl: Sendable, Hashable { name, label, kind: ParamKind, defaultValue: ParamValue }`
  - `enum NodeCategory: String, Codable, Sendable, CaseIterable { input, math, vector, sdf, noise, color, utility, output }`
  - `struct EmitContext: Sendable { inputs: [String: String], outputs: [String: String], params: [String: String], enums: [String: String], types: [String: SocketType] }`
  - `enum NodeBody: Sendable { case template(String), variants(param: String, [String: String]), custom(@Sendable (EmitContext) -> [String]) }`
  - `struct NodeDef: Sendable, Identifiable { id: String, title, category, inputs: [SocketDecl], outputs: [SocketDecl], params: [ParamDecl], generics: [String: [SocketType]], requires: [String], body: NodeBody }` with `input(named:)`, `output(named:)`, `param(named:)`.
  - `struct NodeRegistry: Sendable { init(_ defs: [NodeDef]) throws(RegistryError); subscript(id: String) -> NodeDef?; var all: [NodeDef] }` and `enum RegistryError: Error, Equatable`.

Template placeholder grammar (used by the emitter in Task 12 and validated here): `{in.<socket>}`, `{out.<socket>}`, `{param.<param>}`, `{type.<generic>}`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct NodeRegistryTests {
    private let add = NodeDef(
        id: "test.add", title: "Add", category: .math,
        inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                 SocketDecl(name: "b", type: .generic("T"), default: .value(.float(0)))],
        outputs: [SocketDecl(name: "out", type: .generic("T"))],
        generics: ["T": [.float, .float2, .float3, .float4]],
        body: .template("{out.out} = {in.a} + {in.b};"))

    @Test func lookupByID() throws {
        let reg = try NodeRegistry([add])
        #expect(reg["test.add"]?.title == "Add")
        #expect(reg["nope"] == nil)
        #expect(reg.all.map(\.id) == ["test.add"])
    }

    @Test func duplicateIDsAreRejected() {
        #expect(throws: RegistryError.duplicateID("test.add")) { try NodeRegistry([add, add]) }
    }

    @Test func socketAndParamNamesShareOneNamespace() {
        var def = add
        def.params = [ParamDecl(name: "a", kind: .value(.float, range: nil), defaultValue: .float(1))]
        #expect(throws: RegistryError.duplicateName(def: "test.add", name: "a")) { try NodeRegistry([def]) }
    }

    @Test func templateMayOnlyReferenceDeclaredNames() {
        var def = add
        def.body = .template("{out.out} = {in.a} + {in.zzz};")
        #expect(throws: RegistryError.unknownPlaceholder(def: "test.add", placeholder: "in.zzz")) {
            try NodeRegistry([def])
        }
    }

    @Test func genericNamesMustBeDeclared() {
        var def = add
        def.generics = [:]
        #expect(throws: RegistryError.undeclaredGeneric(def: "test.add", name: "T")) { try NodeRegistry([def]) }
    }

    @Test func variantsMustCoverEveryEnumCase() {
        var def = add
        def.params = [ParamDecl(name: "op", kind: .enumeration(["add", "sub"]), defaultValue: .enumCase("add"))]
        def.body = .variants(param: "op", ["add": "{out.out} = {in.a} + {in.b};"])
        #expect(throws: RegistryError.missingVariantCase(def: "test.add", case: "sub")) { try NodeRegistry([def]) }
    }

    @Test func variantsParamMustBeAnEnum() {
        var def = add
        def.params = [ParamDecl(name: "k", kind: .value(.float, range: nil), defaultValue: .float(0))]
        def.body = .variants(param: "k", [:])
        #expect(throws: RegistryError.variantsParamNotEnum(def: "test.add", param: "k")) { try NodeRegistry([def]) }
    }

    @Test func paramValueLiteralsAndTypes() {
        #expect(ParamValue.float(0.5).mslLiteral == "0.5")
        #expect(ParamValue.float3(.init(1, 2, 3)).mslLiteral == "float3(1.0, 2.0, 3.0)")
        #expect(ParamValue.int(7).mslLiteral == "7")
        #expect(ParamValue.bool(true).mslLiteral == "true")
        #expect(ParamValue.float2(.init(0, 0)).socketType == .float2)
        #expect(ParamValue.enumCase("add").socketType == nil)
        #expect(ParamValue.asset(nil).socketType == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter NodeRegistryTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'NodeDef' in scope`.

- [ ] **Step 3: Write `ParamValue.swift`**

```swift
import Foundation

/// A concrete value stored on a node instance: a socket's unconnected value,
/// a declared parameter, an enum case, or a texture asset reference.
public enum ParamValue: Codable, Sendable, Hashable {
    case float(Float)
    case float2(SIMD2<Float>)
    case float3(SIMD3<Float>)
    case float4(SIMD4<Float>)
    case int(Int32)
    case bool(Bool)
    case enumCase(String)
    case asset(AssetID?)

    /// The socket type this value can feed. `nil` for values that never become uniforms.
    public var socketType: SocketType? {
        switch self {
        case .float: .float
        case .float2: .float2
        case .float3: .float3
        case .float4: .float4
        case .int: .int
        case .bool: .bool
        case .enumCase, .asset: nil
        }
    }

    public var isUniformable: Bool { socketType != nil }

    /// MSL source literal, used only in tests and for `.constant` folding in exports.
    public var mslLiteral: String {
        func f(_ x: Float) -> String {
            x == x.rounded() && abs(x) < 1e7 ? String(format: "%.1f", x) : "\(x)"
        }
        switch self {
        case .float(let x): return f(x)
        case .float2(let v): return "float2(\(f(v.x)), \(f(v.y)))"
        case .float3(let v): return "float3(\(f(v.x)), \(f(v.y)), \(f(v.z)))"
        case .float4(let v): return "float4(\(f(v.x)), \(f(v.y)), \(f(v.z)), \(f(v.w)))"
        case .int(let i): return "\(i)"
        case .bool(let b): return b ? "true" : "false"
        case .enumCase(let c): return c
        case .asset: return "/* asset */"
        }
    }
}

/// What an input socket does when nothing is wired into it.
public enum SocketDefault: Sendable, Hashable, Codable {
    /// Codegen reports a diagnostic if the socket is unconnected.
    case required
    /// The value becomes a per-instance uniform slot, editable in the node body.
    case value(ParamValue)
    /// Falls back to the fragment's interpolated `uv`.
    case uv
}
```

- [ ] **Step 4: Write `NodeDef.swift`**

```swift
import Foundation

public struct SocketDecl: Sendable, Hashable, Codable {
    public var name: String
    public var label: String
    public var type: TypeRef
    public var `default`: SocketDefault

    public init(name: String, label: String? = nil, type: TypeRef, default: SocketDefault = .required) {
        self.name = name
        self.label = label ?? name.capitalized
        self.type = type
        self.default = `default`
    }
}

public enum ParamKind: Sendable, Hashable {
    case value(SocketType, range: ClosedRange<Float>?)
    case enumeration([String])
    case asset
}

public struct ParamDecl: Sendable, Hashable {
    public var name: String
    public var label: String
    public var kind: ParamKind
    public var defaultValue: ParamValue

    public init(name: String, label: String? = nil, kind: ParamKind, defaultValue: ParamValue) {
        self.name = name
        self.label = label ?? name.capitalized
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

public enum NodeCategory: String, Codable, Sendable, CaseIterable {
    case input, math, vector, sdf, noise, color, utility, output
}

/// Everything a custom emitter needs: resolved MSL expressions for each
/// input, variable names for each output, uniform expressions for value
/// params, chosen cases for enum params, and resolved types for generics.
public struct EmitContext: Sendable {
    public var inputs: [String: String]
    public var outputs: [String: String]
    public var params: [String: String]
    public var enums: [String: String]
    public var types: [String: SocketType]

    public init(inputs: [String: String], outputs: [String: String], params: [String: String],
                enums: [String: String], types: [String: SocketType]) {
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.enums = enums; self.types = types
    }
}

public enum NodeBody: Sendable {
    /// One template using `{in.x}`, `{out.x}`, `{param.x}`, `{type.T}` placeholders.
    case template(String)
    /// One template per case of the named enum parameter.
    case variants(param: String, [String: String])
    /// Escape hatch: produce statement lines directly.
    case custom(@Sendable (EmitContext) -> [String])
}

/// A node *type*. Pure data — adding a node to the library is adding one of these.
public struct NodeDef: Sendable, Identifiable {
    public let id: String
    public var title: String
    public var category: NodeCategory
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var params: [ParamDecl]
    public var generics: [String: [SocketType]]
    public var requires: [String]
    public var body: NodeBody

    public init(id: String, title: String, category: NodeCategory,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], requires: [String] = [], body: NodeBody) {
        self.id = id; self.title = title; self.category = category
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.requires = requires; self.body = body
    }

    public func input(named n: String) -> SocketDecl? { inputs.first { $0.name == n } }
    public func output(named n: String) -> SocketDecl? { outputs.first { $0.name == n } }
    public func param(named n: String) -> ParamDecl? { params.first { $0.name == n } }
}
```

- [ ] **Step 5: Write `NodeRegistry.swift`**

```swift
import Foundation

public enum RegistryError: Error, Equatable {
    case duplicateID(String)
    case duplicateName(def: String, name: String)
    case unknownPlaceholder(def: String, placeholder: String)
    case undeclaredGeneric(def: String, name: String)
    case variantsParamNotEnum(def: String, param: String)
    case missingVariantCase(def: String, case: String)
}

/// Validated lookup table of node definitions.
public struct NodeRegistry: Sendable {
    private let defs: [String: NodeDef]

    public init(_ list: [NodeDef]) throws(RegistryError) {
        var table: [String: NodeDef] = [:]
        for def in list {
            if table[def.id] != nil { throw .duplicateID(def.id) }
            try NodeRegistry.validate(def)
            table[def.id] = def
        }
        defs = table
    }

    public subscript(id: String) -> NodeDef? { defs[id] }
    public var all: [NodeDef] { defs.values.sorted { $0.id < $1.id } }

    static let placeholderPattern = /\{(in|out|param|type)\.([A-Za-z_][A-Za-z0-9_]*)\}/

    private static func validate(_ def: NodeDef) throws(RegistryError) {
        var seen = Set<String>()
        for name in def.inputs.map(\.name) + def.outputs.map(\.name) + def.params.map(\.name) {
            if !seen.insert(name).inserted { throw .duplicateName(def: def.id, name: name) }
        }
        for decl in def.inputs + def.outputs {
            if case .generic(let g) = decl.type, def.generics[g] == nil {
                throw .undeclaredGeneric(def: def.id, name: g)
            }
        }
        switch def.body {
        case .template(let t):
            try checkPlaceholders(t, in: def)
        case .variants(let param, let table):
            guard let p = def.param(named: param), case .enumeration(let cases) = p.kind else {
                throw .variantsParamNotEnum(def: def.id, param: param)
            }
            for c in cases where table[c] == nil { throw .missingVariantCase(def: def.id, case: c) }
            for t in table.values { try checkPlaceholders(t, in: def) }
        case .custom:
            break
        }
    }

    private static func checkPlaceholders(_ template: String, in def: NodeDef) throws(RegistryError) {
        for m in template.matches(of: placeholderPattern) {
            let kind = String(m.1), name = String(m.2)
            let ok: Bool = switch kind {
            case "in": def.input(named: name) != nil
            case "out": def.output(named: name) != nil
            case "param": def.param(named: name) != nil
            case "type": def.generics[name] != nil
            default: false
            }
            if !ok { throw .unknownPlaceholder(def: def.id, placeholder: "\(kind).\(name)") }
        }
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter NodeRegistryTests 2>&1 | tail -3`
Expected: all NodeRegistryTests pass.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): ParamValue, NodeDef and validated NodeRegistry

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 6: Graph, ShaderDocument and EditorViewState

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Graph.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/GraphCodableTests.swift`

**Interfaces:**
- Consumes: IDs, `ParamValue`, `SocketDecl`.
- Produces:
  - `struct SocketRef: Hashable, Codable, Sendable { var node: NodeID; var socket: String; init(_ node: NodeID, _ socket: String) }`
  - `enum NodeKind: Hashable, Codable, Sendable { case builtin(String), group(GroupID), groupInput, groupOutput }`
  - `struct NodeInstance: Codable, Sendable, Hashable, Identifiable { let id: NodeID; var kind; var position: CGPoint; var params: [ParamID: ParamValue]; var customTitle: String?; var collapsed: Bool }`
  - `enum DraculaAccent: String, Codable, Sendable, CaseIterable { cyan, green, orange, pink, purple, yellow, muted }`
  - `struct StickyNote`, `struct CommentFrame` (Codable, Sendable, Hashable, Identifiable)
  - `struct Graph: Codable, Sendable, Hashable` with `nodes: [NodeID: NodeInstance]`, `inputs: [SocketRef: SocketRef]`, `stickies`, `frames`, and methods `source(feeding:)`, `connect(_:to:)`, `disconnect(_:)`, `remove(node:)`, `edges(of:)`, `upstreamNodes(of:)`.
  - `struct GroupDefinition`, `struct DocumentSettings`, `enum TimeMode`, `struct ShaderDocument` with `static let currentFormatVersion = 1` and `init()` giving an empty root graph.
  - `enum GraphPath: Hashable, Codable, Sendable { case root, definition(GroupID) }`, `struct Camera { pan: CGSize; zoom: CGFloat }`, `struct EditorViewState`.

JSON shape: `nodes`, `stickies`, `frames`, `definitions` encode as **arrays** (dictionaries keyed by UUID types would otherwise encode as flat `[k, v, k, v]` arrays); edges encode as `[{"to": {...}, "from": {...}}]`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct GraphCodableTests {
    private func twoNodeGraph() -> (Graph, NodeID, NodeID) {
        let a = NodeInstance(kind: .builtin("input.uv"), position: CGPoint(x: 10, y: 20))
        let b = NodeInstance(kind: .builtin("output.fragment"), position: CGPoint(x: 300, y: 20),
                             params: ["gain": .float(2)])
        var g = Graph()
        g.nodes[a.id] = a
        g.nodes[b.id] = b
        g.connect(SocketRef(a.id, "uv"), to: SocketRef(b.id, "color"))
        return (g, a.id, b.id)
    }

    @Test func documentRoundTripsThroughJSON() throws {
        let (g, _, _) = twoNodeGraph()
        var doc = ShaderDocument()
        doc.root = g
        let data = try JSONEncoder().encode(doc)
        let back = try JSONDecoder().decode(ShaderDocument.self, from: data)
        #expect(back == doc)
        #expect(back.formatVersion == ShaderDocument.currentFormatVersion)
    }

    @Test func jsonUsesArraysNotFlattenedDictionaries() throws {
        let (g, _, _) = twoNodeGraph()
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(g)) as! [String: Any]
        #expect((json["nodes"] as? [[String: Any]])?.count == 2)
        let edges = json["edges"] as? [[String: Any]]
        #expect(edges?.count == 1)
        #expect(edges?.first?["to"] != nil)
        #expect(edges?.first?["from"] != nil)
    }

    @Test func connectingASecondWireReplacesTheFirst() {
        var (g, a, b) = twoNodeGraph()
        let c = NodeInstance(kind: .builtin("input.time"))
        g.nodes[c.id] = c
        g.connect(SocketRef(c.id, "time"), to: SocketRef(b, "color"))
        #expect(g.source(feeding: SocketRef(b, "color")) == SocketRef(c.id, "time"))
        #expect(g.inputs.count == 1)
        _ = a
    }

    @Test func removingANodeRemovesItsWires() {
        var (g, a, b) = twoNodeGraph()
        g.remove(node: a)
        #expect(g.nodes[a] == nil)
        #expect(g.source(feeding: SocketRef(b, "color")) == nil)
        #expect(g.inputs.isEmpty)
    }

    @Test func upstreamNodesAreTransitive() {
        var (g, a, b) = twoNodeGraph()
        let mid = NodeInstance(kind: .builtin("math.math"))
        g.nodes[mid.id] = mid
        g.connect(SocketRef(a, "uv"), to: SocketRef(mid.id, "a"))
        g.connect(SocketRef(mid.id, "out"), to: SocketRef(b, "color"))
        #expect(g.upstreamNodes(of: b) == Set([a, mid.id]))
        #expect(g.upstreamNodes(of: a).isEmpty)
    }

    @Test func viewStateRoundTrips() throws {
        var vs = EditorViewState()
        vs.cameras[.root] = Camera(pan: CGSize(width: 5, height: -3), zoom: 1.5)
        vs.selection = [NodeID()]
        let data = try JSONEncoder().encode(vs)
        #expect(try JSONDecoder().decode(EditorViewState.self, from: data) == vs)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter GraphCodableTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'Graph' in scope`.

- [ ] **Step 3: Write `Graph.swift`**

```swift
import Foundation
import CoreGraphics

/// A socket on a specific node, addressed by **name** (spec §3).
public struct SocketRef: Hashable, Codable, Sendable {
    public var node: NodeID
    public var socket: String
    public init(_ node: NodeID, _ socket: String) { self.node = node; self.socket = socket }
}

public enum NodeKind: Hashable, Codable, Sendable {
    case builtin(String)
    case group(GroupID)
    case groupInput
    case groupOutput
}

public struct NodeInstance: Codable, Sendable, Hashable, Identifiable {
    public let id: NodeID
    public var kind: NodeKind
    public var position: CGPoint
    /// Unconnected input values and declared parameters, keyed by socket/param name.
    public var params: [ParamID: ParamValue]
    public var customTitle: String?
    public var collapsed: Bool

    public init(id: NodeID = NodeID(), kind: NodeKind, position: CGPoint = .zero,
                params: [ParamID: ParamValue] = [:], customTitle: String? = nil, collapsed: Bool = false) {
        self.id = id; self.kind = kind; self.position = position
        self.params = params; self.customTitle = customTitle; self.collapsed = collapsed
    }
}

public enum DraculaAccent: String, Codable, Sendable, CaseIterable {
    case cyan, green, orange, pink, purple, yellow, muted
}

public struct StickyNote: Codable, Sendable, Hashable, Identifiable {
    public let id: StickyID
    public var text: String
    public var frame: CGRect
    public var accent: DraculaAccent
    public init(id: StickyID = StickyID(), text: String, frame: CGRect, accent: DraculaAccent = .muted) {
        self.id = id; self.text = text; self.frame = frame; self.accent = accent
    }
}

public struct CommentFrame: Codable, Sendable, Hashable, Identifiable {
    public let id: FrameID
    public var title: String
    public var frame: CGRect
    public var accent: DraculaAccent
    public var collapsed: Bool
    public init(id: FrameID = FrameID(), title: String, frame: CGRect, accent: DraculaAccent = .muted, collapsed: Bool = false) {
        self.id = id; self.title = title; self.frame = frame; self.accent = accent; self.collapsed = collapsed
    }
}

/// Nodes plus wires. Wires are stored **input → output** so each input has at
/// most one source by construction (spec §3).
public struct Graph: Sendable, Hashable {
    public var nodes: [NodeID: NodeInstance] = [:]
    public var inputs: [SocketRef: SocketRef] = [:]
    public var stickies: [StickyID: StickyNote] = [:]
    public var frames: [FrameID: CommentFrame] = [:]

    public init() {}

    public func source(feeding input: SocketRef) -> SocketRef? { inputs[input] }

    public mutating func connect(_ from: SocketRef, to input: SocketRef) { inputs[input] = from }

    public mutating func disconnect(_ input: SocketRef) { inputs[input] = nil }

    public mutating func remove(node id: NodeID) {
        nodes[id] = nil
        inputs = inputs.filter { $0.key.node != id && $0.value.node != id }
    }

    /// All wires touching a node, as (input, source) pairs.
    public func edges(of id: NodeID) -> [(to: SocketRef, from: SocketRef)] {
        inputs.filter { $0.key.node == id || $0.value.node == id }.map { (to: $0.key, from: $0.value) }
    }

    public func upstreamNodes(of id: NodeID) -> Set<NodeID> {
        var seen = Set<NodeID>()
        var stack = [id]
        while let n = stack.popLast() {
            for (to, from) in inputs where to.node == n {
                if seen.insert(from.node).inserted { stack.append(from.node) }
            }
        }
        return seen
    }
}

extension Graph: Codable {
    private struct Edge: Codable { var to: SocketRef; var from: SocketRef }
    private enum Keys: String, CodingKey { case nodes, edges, stickies, frames }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        nodes = Dictionary(uniqueKeysWithValues: try c.decode([NodeInstance].self, forKey: .nodes).map { ($0.id, $0) })
        inputs = Dictionary(uniqueKeysWithValues: try c.decode([Edge].self, forKey: .edges).map { ($0.to, $0.from) })
        stickies = Dictionary(uniqueKeysWithValues: try c.decodeIfPresent([StickyNote].self, forKey: .stickies)?.map { ($0.id, $0) } ?? [])
        frames = Dictionary(uniqueKeysWithValues: try c.decodeIfPresent([CommentFrame].self, forKey: .frames)?.map { ($0.id, $0) } ?? [])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(nodes.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .nodes)
        try c.encode(inputs.map { Edge(to: $0.key, from: $0.value) }
            .sorted { ($0.to.node.raw.uuidString, $0.to.socket) < ($1.to.node.raw.uuidString, $1.to.socket) }, forKey: .edges)
        try c.encode(stickies.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .stickies)
        try c.encode(frames.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .frames)
    }
}
```

- [ ] **Step 4: Write `ShaderDocument.swift`**

```swift
import Foundation
import CoreGraphics

/// A reusable function: one definition, many `NodeKind.group` instances (spec §3, §4).
public struct GroupDefinition: Codable, Sendable, Hashable, Identifiable {
    public let id: GroupID
    public var name: String
    public var inputs: [SocketDecl]
    public var outputs: [SocketDecl]
    public var graph: Graph
    public var accent: DraculaAccent

    public init(id: GroupID = GroupID(), name: String, inputs: [SocketDecl] = [], outputs: [SocketDecl] = [],
                graph: Graph = Graph(), accent: DraculaAccent = .purple) {
        self.id = id; self.name = name; self.inputs = inputs; self.outputs = outputs
        self.graph = graph; self.accent = accent
    }
}

public enum TimeMode: String, Codable, Sendable { case wallClock, fixedRate }

public struct DocumentSettings: Codable, Sendable, Hashable {
    public var previewSize: CGSize = CGSize(width: 512, height: 512)
    public var timeMode: TimeMode = .wallClock
    public init() {}
}

public struct ShaderDocument: Sendable, Hashable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int = ShaderDocument.currentFormatVersion
    public var root: Graph = Graph()
    public var definitions: [GroupID: GroupDefinition] = [:]
    public var settings: DocumentSettings = DocumentSettings()

    public init() {}
}

extension ShaderDocument: Codable {
    private enum Keys: String, CodingKey { case formatVersion, root, definitions, settings }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        root = try c.decode(Graph.self, forKey: .root)
        definitions = Dictionary(uniqueKeysWithValues: try c.decode([GroupDefinition].self, forKey: .definitions).map { ($0.id, $0) })
        settings = try c.decode(DocumentSettings.self, forKey: .settings)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(root, forKey: .root)
        try c.encode(definitions.values.sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }, forKey: .definitions)
        try c.encode(settings, forKey: .settings)
    }
}
```

- [ ] **Step 5: Write `EditorViewState.swift`**

```swift
import Foundation
import CoreGraphics

/// Which graph the canvas is bound to.
public enum GraphPath: Hashable, Codable, Sendable {
    case root
    case definition(GroupID)
}

public struct Camera: Codable, Sendable, Hashable {
    public var pan: CGSize
    public var zoom: CGFloat
    public init(pan: CGSize = .zero, zoom: CGFloat = 1) { self.pan = pan; self.zoom = zoom }
}

/// Persisted next to the document, never part of an undo snapshot (spec §3, §5).
public struct EditorViewState: Codable, Sendable, Hashable {
    public var cameras: [GraphPath: Camera] = [:]
    public var editingStack: [NodeID] = []
    public var viewer: SocketRef? = nil
    public var selection: Set<NodeID> = []
    public init() {}
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter GraphCodableTests 2>&1 | tail -3`
Expected: all GraphCodableTests pass.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): Graph, ShaderDocument and EditorViewState with stable JSON

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 7: MSL stdlib, the M1 node library, and the sample document

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/MSLStdlib.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/SampleDocuments.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/BuiltinLibraryTests.swift`

**Interfaces:**
- Consumes: `NodeDef`, `NodeRegistry`, `ShaderDocument`.
- Produces:
  - `struct MSLFunction: Sendable { name: String; dependencies: [String]; source: String }`, `enum MSLStdlib { static let functions: [String: MSLFunction]; static func resolve(_ names: [String]) -> [MSLFunction] }` — dependency-ordered, deduplicated.
  - `extension NodeRegistry { static let builtin: NodeRegistry }` containing the 12 definitions below.
  - `extension ShaderDocument { static func sample() -> ShaderDocument }`.
  - Definition IDs (used verbatim by every later task): `input.uv`, `input.time`, `input.resolution`, `input.float`, `input.color`, `math.math`, `math.mix`, `math.smoothstep`, `vector.combine`, `vector.separate`, `vector.length`, `noise.value`, `output.fragment`.

Design note: a `Constant` whose *output type* changes with an enum cannot be one definition — generics resolve from connected inputs, not from parameters. So constants are one definition per type (`input.float`, `input.color` now; `input.float2`, `input.float3`, `input.int`, `input.bool` in M3) and the palette groups them under "Constant". Update spec §13 wording when M3 lands.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct BuiltinLibraryTests {
    @Test func registryContainsTheM1Set() {
        let ids = Set(NodeRegistry.builtin.all.map(\.id))
        let expected: Set<String> = [
            "input.uv", "input.time", "input.resolution", "input.float", "input.color",
            "math.math", "math.mix", "math.smoothstep",
            "vector.combine", "vector.separate", "vector.length",
            "noise.value", "output.fragment",
        ]
        #expect(ids == expected)
    }

    @Test func everyRequiredStdlibFunctionExists() {
        for def in NodeRegistry.builtin.all {
            for name in def.requires {
                #expect(MSLStdlib.functions[name] != nil, "\(def.id) requires \(name)")
            }
        }
    }

    @Test func stdlibResolvesDependenciesInOrderWithoutDuplicates() {
        let fns = MSLStdlib.resolve(["valueNoise", "valueNoise", "hash21"]).map(\.name)
        #expect(fns == ["hash21", "valueNoise"])
    }

    @Test func mathNodeHasFifteenVariants() throws {
        let def = try #require(NodeRegistry.builtin["math.math"])
        guard case .variants(let param, let table) = def.body else { Issue.record("expected variants"); return }
        #expect(param == "op")
        #expect(table.count == 15)
    }

    @Test func sampleDocumentHasOneOutputAndWires() {
        let doc = ShaderDocument.sample()
        let outputs = doc.root.nodes.values.filter { $0.kind == .builtin("output.fragment") }
        #expect(outputs.count == 1)
        #expect(doc.root.inputs.count >= 8)
        #expect(doc.definitions.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter BuiltinLibraryTests 2>&1 | tail -3`
Expected: compile error, `type 'NodeRegistry' has no member 'builtin'`.

- [ ] **Step 3: Write `MSLStdlib.swift`**

```swift
import Foundation

public struct MSLFunction: Sendable {
    public let name: String
    public let dependencies: [String]
    public let source: String
}

/// Hand-written MSL helpers pulled in by `NodeDef.requires`. Every function is
/// prefixed `mn_` so generated code can never collide with Metal's own names.
public enum MSLStdlib {
    public static let functions: [String: MSLFunction] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// Returns the closure of `names` over dependencies, dependencies first, each once.
    public static func resolve(_ names: [String]) -> [MSLFunction] {
        var out: [MSLFunction] = []
        var seen = Set<String>()
        func visit(_ n: String) {
            guard !seen.contains(n), let f = functions[n] else { return }
            seen.insert(n)
            f.dependencies.forEach(visit)
            out.append(f)
        }
        names.forEach(visit)
        return out
    }

    private static let all: [MSLFunction] = [
        MSLFunction(name: "hash21", dependencies: [], source: """
        float mn_hash21(float2 p) {
            p = fract(p * float2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        """),
        MSLFunction(name: "valueNoise", dependencies: ["hash21"], source: """
        float mn_valueNoise(float2 p) {
            float2 i = floor(p);
            float2 f = fract(p);
            float2 s = f * f * (3.0 - 2.0 * f);
            float a = mn_hash21(i);
            float b = mn_hash21(i + float2(1.0, 0.0));
            float c = mn_hash21(i + float2(0.0, 1.0));
            float d = mn_hash21(i + float2(1.0, 1.0));
            return mix(mix(a, b, s.x), mix(c, d, s.x), s.y);
        }
        """),
    ]
}
```

- [ ] **Step 4: Write `BuiltinNodes.swift`**

```swift
import Foundation

public extension NodeRegistry {
    /// The M1 library. Every entry is data; see spec §8 and §13.
    static let builtin: NodeRegistry = {
        do { return try NodeRegistry(BuiltinNodes.all) }
        catch { fatalError("Builtin node library is invalid: \(error)") }
    }()
}

public enum BuiltinNodes {
    static let anyFloat: [SocketType] = [.float, .float2, .float3, .float4]
    static let anyVector: [SocketType] = [.float2, .float3, .float4]

    public static let all: [NodeDef] = [
        // MARK: Input
        NodeDef(id: "input.uv", title: "UV", category: .input,
                outputs: [SocketDecl(name: "uv", type: .concrete(.float2))],
                params: [ParamDecl(name: "mode", kind: .enumeration(["normalized", "aspect"]), defaultValue: .enumCase("normalized"))],
                body: .variants(param: "mode", [
                    "normalized": "{out.uv} = in.uv;",
                    "aspect": "{out.uv} = (in.uv - 0.5) * (u.resolution / u.resolution.y);",
                ])),
        NodeDef(id: "input.time", title: "Time", category: .input,
                outputs: [SocketDecl(name: "time", type: .concrete(.float))],
                body: .template("{out.time} = u.time;")),
        NodeDef(id: "input.resolution", title: "Resolution", category: .input,
                outputs: [SocketDecl(name: "resolution", type: .concrete(.float2))],
                body: .template("{out.resolution} = u.resolution;")),
        NodeDef(id: "input.float", title: "Float", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                params: [ParamDecl(name: "value", kind: .value(.float, range: -10...10), defaultValue: .float(1))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.color", title: "Color", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                params: [ParamDecl(name: "value", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)))],
                body: .template("{out.out} = {param.value};")),

        // MARK: Math
        NodeDef(id: "math.math", title: "Math", category: .math,
                inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                         SocketDecl(name: "b", type: .generic("T"), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                params: [ParamDecl(name: "op", label: "Operation",
                                   kind: .enumeration(["add", "subtract", "multiply", "divide", "power", "modulo",
                                                       "minimum", "maximum", "absolute", "floor", "fract", "sqrt",
                                                       "sine", "cosine", "tangent"]),
                                   defaultValue: .enumCase("add"))],
                generics: ["T": anyFloat],
                body: .variants(param: "op", [
                    "add":      "{out.out} = {in.a} + {in.b};",
                    "subtract": "{out.out} = {in.a} - {in.b};",
                    "multiply": "{out.out} = {in.a} * {in.b};",
                    "divide":   "{out.out} = {in.a} / {in.b};",
                    "power":    "{out.out} = pow({in.a}, {in.b});",
                    "modulo":   "{out.out} = fmod({in.a}, {in.b});",
                    "minimum":  "{out.out} = min({in.a}, {in.b});",
                    "maximum":  "{out.out} = max({in.a}, {in.b});",
                    "absolute": "{out.out} = abs({in.a});",
                    "floor":    "{out.out} = floor({in.a});",
                    "fract":    "{out.out} = fract({in.a});",
                    "sqrt":     "{out.out} = sqrt({in.a});",
                    "sine":     "{out.out} = sin({in.a});",
                    "cosine":   "{out.out} = cos({in.a});",
                    "tangent":  "{out.out} = tan({in.a});",
                ])),
        NodeDef(id: "math.mix", title: "Mix", category: .math,
                inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                         SocketDecl(name: "b", type: .generic("T"), default: .value(.float(1))),
                         SocketDecl(name: "t", label: "Factor", type: .concrete(.float), default: .value(.float(0.5)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = mix({in.a}, {in.b}, {in.t});")),
        NodeDef(id: "math.smoothstep", title: "Smoothstep", category: .math,
                inputs: [SocketDecl(name: "edge0", label: "Edge 0", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "edge1", label: "Edge 1", type: .concrete(.float), default: .value(.float(1))),
                         SocketDecl(name: "x", type: .generic("T"), default: .value(.float(0.5)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = smoothstep({type.T}({in.edge0}), {type.T}({in.edge1}), {in.x});")),

        // MARK: Vector
        NodeDef(id: "vector.combine", title: "Combine XYZ", category: .vector,
                inputs: [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "y", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "z", type: .concrete(.float), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .concrete(.float3))],
                body: .template("{out.out} = float3({in.x}, {in.y}, {in.z});")),
        NodeDef(id: "vector.separate", title: "Separate XYZ", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .concrete(.float3), default: .value(.float3(.init(0, 0, 0))))],
                outputs: [SocketDecl(name: "x", type: .concrete(.float)),
                          SocketDecl(name: "y", type: .concrete(.float)),
                          SocketDecl(name: "z", type: .concrete(.float))],
                body: .template("{out.x} = {in.v}.x;\n{out.y} = {in.v}.y;\n{out.z} = {in.v}.z;")),
        NodeDef(id: "vector.length", title: "Length", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .generic("T"), default: .value(.float2(.init(0, 0))))],
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                generics: ["T": anyVector],
                body: .template("{out.out} = length({in.v});")),

        // MARK: Noise
        NodeDef(id: "noise.value", title: "Value Noise", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)))],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                requires: ["valueNoise"],
                body: .template("{out.out} = mn_valueNoise({in.uv} * {in.scale});")),

        // MARK: Output
        NodeDef(id: "output.fragment", title: "Fragment Output", category: .output,
                inputs: [SocketDecl(name: "color", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))))],
                body: .template("return {in.color};")),
    ]
}
```

- [ ] **Step 5: Write `SampleDocuments.swift`**

```swift
import Foundation
import CoreGraphics

public extension ShaderDocument {
    /// The graph the app opens with: UV-driven gradient, animated blue channel,
    /// value-noise mixed with a tint. Exercises conversions, generics, variants,
    /// stdlib `requires`, and three uniform slots of different alignment.
    static func sample() -> ShaderDocument {
        func node(_ id: String, _ x: CGFloat, _ y: CGFloat, _ params: [ParamID: ParamValue] = [:]) -> NodeInstance {
            NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: y), params: params)
        }
        let uv     = node("input.uv", 0, 0)
        let time   = node("input.time", 0, 160)
        let speed  = node("input.float", 0, 280, ["value": .float(0.25)])
        let mul    = node("math.math", 220, 200, ["op": .enumCase("multiply")])
        let sine   = node("math.math", 440, 200, ["op": .enumCase("sine")])
        let sep    = node("vector.separate", 220, 0)
        let comb   = node("vector.combine", 660, 60)
        let noise  = node("noise.value", 440, 360, ["scale": .float(6)])
        let tint   = node("input.color", 660, 360, ["value": .float4(.init(0.74, 0.58, 0.98, 1))])
        let mixN   = node("math.mix", 880, 200)
        let out    = node("output.fragment", 1100, 200)

        var g = Graph()
        for n in [uv, time, speed, mul, sine, sep, comb, noise, tint, mixN, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(time.id, "time"),  to: SocketRef(mul.id, "a"))
        g.connect(SocketRef(speed.id, "out"),  to: SocketRef(mul.id, "b"))
        g.connect(SocketRef(mul.id, "out"),    to: SocketRef(sine.id, "a"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(sep.id, "v"))       // float2 → float3
        g.connect(SocketRef(sep.id, "x"),      to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"),      to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(sine.id, "out"),   to: SocketRef(comb.id, "z"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(noise.id, "uv"))
        g.connect(SocketRef(comb.id, "out"),   to: SocketRef(mixN.id, "a"))      // T = float3
        g.connect(SocketRef(tint.id, "out"),   to: SocketRef(mixN.id, "b"))      // color → float3
        g.connect(SocketRef(noise.id, "out"),  to: SocketRef(mixN.id, "t"))
        g.connect(SocketRef(mixN.id, "out"),   to: SocketRef(out.id, "color"))   // float3 → color

        var doc = ShaderDocument()
        doc.root = g
        return doc
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter BuiltinLibraryTests 2>&1 | tail -3`
Expected: all BuiltinLibraryTests pass.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): MSL stdlib, M1 builtin node library, sample document

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 8: Diagnostics and structural validation

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ValidationTests.swift`

**Interfaces:**
- Consumes: `Graph`, `NodeRegistry`.
- Produces:
  - `struct Diagnostic: Sendable, Hashable { enum Severity { error, warning }; severity; message: String; node: NodeID?; socket: String? }`
  - `enum GenerationError: Error, Equatable { case invalid([Diagnostic]) }`
  - `enum OutputTarget: Sendable, Hashable { case fragment, stitchable(StitchableKind) }`, `enum StitchableKind: String, Sendable, CaseIterable { colorEffect, distortionEffect, layerEffect }` — only `.fragment` is implemented in this plan; `.stitchable` validates as an error "not yet supported" until M3.
  - `enum GraphValidator { static func validate(_ graph: Graph, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] }` and `static func terminal(in graph: Graph) -> NodeID?`.

Checks, in order: unknown builtin id · unsupported kind (`group`, `groupInput`, `groupOutput`, until M4) · unsupported target · exactly one `output.fragment` · every wire endpoint exists and names a declared socket · no cycles · every `.required` input is wired. Type compatibility is Task 9's job.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ValidationTests {
    let reg = NodeRegistry.builtin

    private func errors(_ g: Graph, target: OutputTarget = .fragment) -> [String] {
        GraphValidator.validate(g, registry: reg, target: target).filter { $0.severity == .error }.map(\.message)
    }

    @Test func sampleDocumentIsValid() {
        #expect(errors(ShaderDocument.sample().root).isEmpty)
    }

    @Test func missingOutputNode() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("input.uv"))
        #expect(errors(g).contains { $0.contains("Fragment Output") })
    }

    @Test func twoOutputNodesFlagsTheExtra() {
        var g = Graph()
        let a = NodeInstance(kind: .builtin("output.fragment")), b = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[a.id] = a; g.nodes[b.id] = b
        let d = GraphValidator.validate(g, registry: reg, target: .fragment)
        #expect(d.filter { $0.message.contains("only one") }.count == 1)
    }

    @Test func unknownDefinition() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("nope.nope"))
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("output.fragment"))
        #expect(errors(g).contains { $0.contains("nope.nope") })
    }

    @Test func groupsAreNotYetSupported() {
        var g = Graph()
        g.nodes[NodeID()] = NodeInstance(kind: .group(GroupID()))
        g.nodes[NodeID()] = NodeInstance(kind: .builtin("output.fragment"))
        #expect(errors(g).contains { $0.contains("group") })
    }

    @Test func danglingWireEndpoints() {
        var g = Graph()
        let out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[out.id] = out
        g.connect(SocketRef(NodeID(), "uv"), to: SocketRef(out.id, "color"))
        #expect(errors(g).contains { $0.contains("missing node") })
        g.inputs = [:]
        let uv = NodeInstance(kind: .builtin("input.uv")); g.nodes[uv.id] = uv
        g.connect(SocketRef(uv.id, "zzz"), to: SocketRef(out.id, "color"))
        #expect(errors(g).contains { $0.contains("zzz") })
    }

    @Test func cyclesAreReported() {
        var g = Graph()
        let a = NodeInstance(kind: .builtin("math.math")), b = NodeInstance(kind: .builtin("math.math"))
        let out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [a, b, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(a.id, "out"), to: SocketRef(b.id, "a"))
        g.connect(SocketRef(b.id, "out"), to: SocketRef(a.id, "a"))
        g.connect(SocketRef(b.id, "out"), to: SocketRef(out.id, "color"))
        let d = GraphValidator.validate(g, registry: reg, target: .fragment)
        #expect(d.contains { $0.message.contains("cycle") && $0.node != nil })
    }

    @Test func requiredInputsMustBeWired() throws {
        let def = NodeDef(id: "t.req", title: "Req", category: .math,
                          inputs: [SocketDecl(name: "x", type: .concrete(.float), default: .required)],
                          outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                          body: .template("{out.out} = {in.x};"))
        let r = try NodeRegistry(BuiltinNodes.all + [def])
        var g = Graph()
        let n = NodeInstance(kind: .builtin("t.req")), out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[n.id] = n; g.nodes[out.id] = out
        g.connect(SocketRef(n.id, "out"), to: SocketRef(out.id, "color"))
        let d = GraphValidator.validate(g, registry: r, target: .fragment)
        #expect(d.contains { $0.node == n.id && $0.socket == "x" })
    }

    @Test func stitchableTargetIsRejectedUntilM3() {
        #expect(errors(ShaderDocument.sample().root, target: .stitchable(.colorEffect)).contains { $0.contains("not yet supported") })
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ValidationTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'GraphValidator' in scope`.

- [ ] **Step 3: Write `Diagnostic.swift`**

```swift
import Foundation

public struct Diagnostic: Sendable, Hashable {
    public enum Severity: Sendable { case error, warning }
    public var severity: Severity
    public var message: String
    public var node: NodeID?
    public var socket: String?

    public init(_ severity: Severity = .error, _ message: String, node: NodeID? = nil, socket: String? = nil) {
        self.severity = severity; self.message = message; self.node = node; self.socket = socket
    }
}

public enum GenerationError: Error, Equatable {
    case invalid([Diagnostic])
}

public enum StitchableKind: String, Sendable, CaseIterable, Codable {
    case colorEffect, distortionEffect, layerEffect
}

/// What the generated program is for. Only `.fragment` is implemented before M3.
public enum OutputTarget: Sendable, Hashable {
    case fragment
    case stitchable(StitchableKind)
}
```

- [ ] **Step 4: Write `Validation.swift`**

```swift
import Foundation

public enum GraphValidator {
    public static let fragmentTerminalID = "output.fragment"

    public static func terminal(in graph: Graph) -> NodeID? {
        graph.nodes.values
            .filter { $0.kind == .builtin(fragmentTerminalID) }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
            .first
    }

    public static func validate(_ graph: Graph, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out: [Diagnostic] = []

        if case .stitchable = target {
            out.append(Diagnostic(.error, "SwiftUI stitchable output is not yet supported"))
        }

        // Definitions and kinds.
        var defs: [NodeID: NodeDef] = [:]
        for n in graph.nodes.values {
            switch n.kind {
            case .builtin(let id):
                if let d = registry[id] { defs[n.id] = d }
                else { out.append(Diagnostic(.error, "Unknown node type “\(id)”", node: n.id)) }
            case .group, .groupInput, .groupOutput:
                out.append(Diagnostic(.error, "Node groups are not yet supported", node: n.id))
            }
        }

        // Exactly one terminal.
        let terminals = graph.nodes.values.filter { $0.kind == .builtin(fragmentTerminalID) }
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
        if terminals.isEmpty {
            out.append(Diagnostic(.error, "Graph has no Fragment Output node"))
        }
        for extra in terminals.dropFirst() {
            out.append(Diagnostic(.error, "A graph may have only one Fragment Output", node: extra.id))
        }

        // Wire endpoints.
        for (to, from) in graph.inputs {
            guard let toDef = defs[to.node] else {
                if graph.nodes[to.node] == nil { out.append(Diagnostic(.error, "Wire ends at a missing node")) }
                continue
            }
            guard let fromDef = defs[from.node] else {
                if graph.nodes[from.node] == nil { out.append(Diagnostic(.error, "Wire starts at a missing node", node: to.node, socket: to.socket)) }
                continue
            }
            if toDef.input(named: to.socket) == nil {
                out.append(Diagnostic(.error, "No input socket named “\(to.socket)” on \(toDef.title)", node: to.node, socket: to.socket))
            }
            if fromDef.output(named: from.socket) == nil {
                out.append(Diagnostic(.error, "No output socket named “\(from.socket)” on \(fromDef.title)", node: from.node, socket: from.socket))
            }
        }

        // Cycles — iterative DFS with colouring.
        enum Mark { case visiting, done }
        var marks: [NodeID: Mark] = [:]
        func sources(of n: NodeID) -> [NodeID] {
            graph.inputs.filter { $0.key.node == n }.map(\.value.node).filter { graph.nodes[$0] != nil }
        }
        for start in graph.nodes.keys.sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) where marks[start] == nil {
            var stack: [(NodeID, [NodeID])] = [(start, sources(of: start))]
            marks[start] = .visiting
            while var (n, pending) = stack.last {
                if let next = pending.popLast() {
                    stack[stack.count - 1] = (n, pending)
                    switch marks[next] {
                    case .visiting:
                        out.append(Diagnostic(.error, "Wires form a cycle", node: next))
                    case .done: break
                    case nil:
                        marks[next] = .visiting
                        stack.append((next, sources(of: next)))
                    }
                } else {
                    marks[n] = .done
                    stack.removeLast()
                }
            }
        }

        // Required inputs.
        for (id, def) in defs {
            for decl in def.inputs where decl.default == .required && graph.inputs[SocketRef(id, decl.name)] == nil {
                out.append(Diagnostic(.error, "“\(decl.label)” must be connected", node: id, socket: decl.name))
            }
        }
        return out
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter ValidationTests 2>&1 | tail -3`
Expected: all ValidationTests pass.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): diagnostics and structural graph validation

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 9: Topological order from the terminal (dead code elimination for free)

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/TopoSort.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TopoSortTests.swift`

**Interfaces:**
- Consumes: `Graph`.
- Produces: `enum TopoSort { static func order(_ graph: Graph, from terminal: NodeID) -> [NodeID] }` — sources first, terminal last, **only nodes reachable upstream of the terminal**, deterministic (ties broken by UUID string). Assumes the graph is acyclic (Task 8 ran first).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct TopoSortTests {
    @Test func sourcesComeBeforeConsumersAndTerminalIsLast() {
        let doc = ShaderDocument.sample()
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        #expect(order.last == terminal)
        var seen = Set<NodeID>()
        for id in order {
            for (to, from) in doc.root.inputs where to.node == id {
                #expect(seen.contains(from.node), "\(from.node) must precede \(id)")
            }
            seen.insert(id)
        }
        #expect(Set(order) == doc.root.upstreamNodes(of: terminal).union([terminal]))
    }

    @Test func unreachableNodesAreDropped() {
        var doc = ShaderDocument.sample()
        let orphan = NodeInstance(kind: .builtin("noise.value"))
        doc.root.nodes[orphan.id] = orphan
        let terminal = GraphValidator.terminal(in: doc.root)!
        #expect(!TopoSort.order(doc.root, from: terminal).contains(orphan.id))
    }

    @Test func orderIsDeterministic() {
        let doc = ShaderDocument.sample()
        let terminal = GraphValidator.terminal(in: doc.root)!
        let a = TopoSort.order(doc.root, from: terminal)
        let b = TopoSort.order(doc.root, from: terminal)
        #expect(a == b)
    }

    @Test func sharedSourceAppearsOnce() {
        let doc = ShaderDocument.sample()   // input.uv feeds two nodes
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        #expect(order.count == Set(order).count)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter TopoSortTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'TopoSort' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public enum TopoSort {
    /// Post-order DFS upstream from `terminal`. Nodes not reachable from the
    /// terminal never appear, which is the spec's "DCE for free" (§9).
    public static func order(_ graph: Graph, from terminal: NodeID) -> [NodeID] {
        var result: [NodeID] = []
        var done = Set<NodeID>()

        func sources(of n: NodeID) -> [NodeID] {
            var s = Set<NodeID>()
            for (to, from) in graph.inputs where to.node == n && graph.nodes[from.node] != nil { s.insert(from.node) }
            return s.sorted { $0.raw.uuidString < $1.raw.uuidString }
        }

        var stack: [(NodeID, [NodeID])] = [(terminal, sources(of: terminal))]
        var onStack: Set<NodeID> = [terminal]
        while var (n, pending) = stack.last {
            if let next = pending.popLast() {
                stack[stack.count - 1] = (n, pending)
                if !done.contains(next) && !onStack.contains(next) {
                    onStack.insert(next)
                    stack.append((next, sources(of: next)))
                }
            } else {
                stack.removeLast()
                onStack.remove(n)
                if done.insert(n).inserted { result.append(n) }
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter TopoSortTests 2>&1 | tail -3`
Expected: all TopoSortTests pass.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): reachable-only topological order

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 10: Generic type resolution and wire compatibility

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/TypeResolver.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/TypeResolverTests.swift`

**Interfaces:**
- Consumes: `Graph`, `NodeRegistry`, `TopoSort.order`, `ConversionRules`.
- Produces: `struct ResolvedNode: Sendable, Hashable { let id: NodeID; var generics: [String: SocketType]; var inputTypes: [String: SocketType]; var outputTypes: [String: SocketType] }` and `enum TypeResolver { static func resolve(_ graph: Graph, registry: NodeRegistry, order: [NodeID]) -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) }`.

Rule (spec §7.3, made exact): for generic `T` with allowed set `S` (sorted by component count), let `n` = the largest component count among connected inputs typed `T` (`color` counts as 4). If nothing is connected, `T = float` when `float ∈ S`, else the smallest member of `S`. Otherwise `T` = the smallest member of `S` with `componentCount ≥ n`, or the largest member of `S` if none qualifies. Then every wire is checked with `ConversionRules.convert`; an impossible one is an error on the input socket.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct TypeResolverTests {
    let reg = NodeRegistry.builtin

    private func resolve(_ g: Graph) -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        let t = GraphValidator.terminal(in: g)!
        return TypeResolver.resolve(g, registry: reg, order: TopoSort.order(g, from: t))
    }

    private func graph(with builder: (inout Graph, NodeID) -> Void) -> Graph {
        var g = Graph()
        let out = NodeInstance(kind: .builtin("output.fragment"))
        g.nodes[out.id] = out
        builder(&g, out.id)
        return g
    }

    @Test func unconnectedGenericDefaultsToFloat() {
        var mathID = NodeID()
        let g = graph { g, out in
            let m = NodeInstance(kind: .builtin("math.math")); mathID = m.id
            g.nodes[m.id] = m
            g.connect(SocketRef(m.id, "out"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[mathID]?.generics["T"] == .float)
        #expect(r.nodes[mathID]?.outputTypes["out"] == .float)
        #expect(r.diagnostics.isEmpty)
    }

    @Test func genericWidensToLargestConnectedInput() {
        var mixID = NodeID()
        let g = graph { g, out in
            let comb = NodeInstance(kind: .builtin("vector.combine"))
            let f = NodeInstance(kind: .builtin("input.float"))
            let mix = NodeInstance(kind: .builtin("math.mix")); mixID = mix.id
            for n in [comb, f, mix] { g.nodes[n.id] = n }
            g.connect(SocketRef(f.id, "out"), to: SocketRef(mix.id, "a"))      // float
            g.connect(SocketRef(comb.id, "out"), to: SocketRef(mix.id, "b"))   // float3
            g.connect(SocketRef(mix.id, "out"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[mixID]?.generics["T"] == .float3)
        #expect(r.nodes[mixID]?.inputTypes["a"] == .float3)
        #expect(r.nodes[mixID]?.inputTypes["t"] == .float)
    }

    @Test func colorFeedingGenericResolvesToFloat4() {
        var mixID = NodeID()
        let g = graph { g, out in
            let c = NodeInstance(kind: .builtin("input.color"))
            let mix = NodeInstance(kind: .builtin("math.mix")); mixID = mix.id
            g.nodes[c.id] = c; g.nodes[mix.id] = mix
            g.connect(SocketRef(c.id, "out"), to: SocketRef(mix.id, "a"))
            g.connect(SocketRef(mix.id, "out"), to: SocketRef(out, "color"))
        }
        #expect(resolve(g).nodes[mixID]?.generics["T"] == .float4)
    }

    @Test func genericPicksSmallestAllowedThatFits() {
        var lenID = NodeID()
        let g = graph { g, out in
            let f = NodeInstance(kind: .builtin("input.float"))
            let len = NodeInstance(kind: .builtin("vector.length")); lenID = len.id
            g.nodes[f.id] = f; g.nodes[len.id] = len
            g.connect(SocketRef(f.id, "out"), to: SocketRef(len.id, "v"))   // float into {float2,float3,float4}
            g.connect(SocketRef(len.id, "out"), to: SocketRef(out, "color"))
        }
        #expect(resolve(g).nodes[lenID]?.generics["T"] == .float2)
    }

    @Test func sampleDocumentResolvesCleanly() {
        let r = resolve(ShaderDocument.sample().root)
        #expect(r.diagnostics.isEmpty)
        #expect(r.nodes.count == 11)
    }

    @Test func concreteSocketsKeepTheirTypes() {
        var sepID = NodeID()
        let g = graph { g, out in
            let sep = NodeInstance(kind: .builtin("vector.separate")); sepID = sep.id
            g.nodes[sep.id] = sep
            g.connect(SocketRef(sep.id, "x"), to: SocketRef(out, "color"))
        }
        let r = resolve(g)
        #expect(r.nodes[sepID]?.inputTypes["v"] == .float3)
        #expect(r.nodes[sepID]?.outputTypes["x"] == .float)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter TypeResolverTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'TypeResolver' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

public struct ResolvedNode: Sendable, Hashable {
    public let id: NodeID
    public var generics: [String: SocketType]
    public var inputTypes: [String: SocketType]
    public var outputTypes: [String: SocketType]
}

public enum TypeResolver {
    public static func resolve(_ graph: Graph, registry: NodeRegistry, order: [NodeID])
        -> (nodes: [NodeID: ResolvedNode], diagnostics: [Diagnostic]) {
        var resolved: [NodeID: ResolvedNode] = [:]
        var diags: [Diagnostic] = []

        for id in order {
            guard let inst = graph.nodes[id], case .builtin(let defID) = inst.kind, let def = registry[defID] else { continue }

            // 1. Resolve each generic from the connected inputs that use it.
            var generics: [String: SocketType] = [:]
            for (name, allowed) in def.generics {
                let s = allowed.sorted { ($0.componentCount ?? 0) < ($1.componentCount ?? 0) }
                var maxCount: Int? = nil
                for decl in def.inputs where decl.type == .generic(name) {
                    guard let src = graph.inputs[SocketRef(id, decl.name)],
                          let srcType = resolved[src.node]?.outputTypes[src.socket] else { continue }
                    maxCount = max(maxCount ?? 0, srcType.componentCount ?? 0)
                }
                if let n = maxCount {
                    generics[name] = s.first { ($0.componentCount ?? 0) >= n } ?? s.last ?? .float
                } else {
                    generics[name] = s.contains(.float) ? .float : (s.first ?? .float)
                }
            }

            func concrete(_ t: TypeRef) -> SocketType {
                switch t {
                case .concrete(let c): c
                case .generic(let g): generics[g] ?? .float
                }
            }
            let node = ResolvedNode(
                id: id, generics: generics,
                inputTypes: Dictionary(uniqueKeysWithValues: def.inputs.map { ($0.name, concrete($0.type)) }),
                outputTypes: Dictionary(uniqueKeysWithValues: def.outputs.map { ($0.name, concrete($0.type)) }))
            resolved[id] = node

            // 2. Every wire into this node must be convertible.
            for decl in def.inputs {
                guard let src = graph.inputs[SocketRef(id, decl.name)],
                      let srcType = resolved[src.node]?.outputTypes[src.socket] else { continue }
                let dst = node.inputTypes[decl.name]!
                if ConversionRules.convert(from: srcType, to: dst) == nil {
                    diags.append(Diagnostic(.error, "Cannot connect \(srcType.rawValue) to \(dst.rawValue)", node: id, socket: decl.name))
                }
            }
        }
        return (resolved, diags)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter TypeResolverTests 2>&1 | tail -3`
Expected: all TypeResolverTests pass.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): per-instance generic resolution and wire type checking

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 11: Uniform buffer layout

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/UniformLayout.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/UniformLayoutTests.swift`

**Interfaces:**
- Consumes: `SocketType`, `NodeID`.
- Produces:
  - `struct ParamPath: Hashable, Sendable, Codable { var instancePath: [NodeID]; var param: ParamID; init(node: NodeID, param: ParamID) }` — for M1 `instancePath` is always one element; M4 extends it.
  - `struct UniformField: Sendable, Hashable { let name: String; let mslType: String; let offset: Int; let size: Int; let type: SocketType; let path: ParamPath? }` (`path == nil` for reserved fields).
  - `struct UniformLayout: Sendable, Hashable { let fields: [UniformField]; let totalSize: Int; func field(for: ParamPath) -> UniformField?; func reserved(_ name: String) -> UniformField; var mslStruct: String }` with `static let reservedNames = ["resolution", "mouse", "time"]`.
  - `enum UniformLayoutBuilder { static func build(_ requests: [(path: ParamPath, type: SocketType)]) -> UniformLayout }`.

Rules (spec §9.6): reserved fields first (`resolution: float2`, `mouse: float2`, `time: float`), then requests in the order given; **stable-sort by alignment descending**; offsets assigned sequentially with alignment padding; `totalSize` rounded up to 16; user field names are `p0, p1, …` in final order; `bool` stores as `int`.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct UniformLayoutTests {
    let n = NodeID()
    func path(_ p: String) -> ParamPath { ParamPath(node: n, param: p) }

    @Test func emptyLayoutHasOnlyReservedFields() {
        let l = UniformLayoutBuilder.build([])
        #expect(l.fields.map(\.name) == ["resolution", "mouse", "time"])
        #expect(l.reserved("resolution").offset == 0)
        #expect(l.reserved("mouse").offset == 8)
        #expect(l.reserved("time").offset == 16)
        #expect(l.totalSize == 32)
    }

    @Test func fieldsAreSortedByAlignmentDescending() {
        let l = UniformLayoutBuilder.build([(path("a"), .float), (path("b"), .float3), (path("c"), .float2), (path("d"), .int)])
        #expect(l.fields.map(\.mslType) == ["float3", "float2", "float2", "float2", "float", "float", "int"])
        #expect(l.field(for: path("b"))?.offset == 0)
        #expect(l.reserved("resolution").offset == 16)
    }

    @Test func float3OccupiesSixteenBytes() {
        let l = UniformLayoutBuilder.build([(path("a"), .float3), (path("b"), .float3)])
        #expect(l.field(for: path("a"))?.offset == 0)
        #expect(l.field(for: path("b"))?.offset == 16)
        #expect(l.field(for: path("a"))?.size == 16)
    }

    @Test func totalSizeIsMultipleOfSixteen() {
        for k in 0..<6 {
            let reqs = (0..<k).map { (path("p\($0)"), SocketType.float) }
            #expect(UniformLayoutBuilder.build(reqs).totalSize % 16 == 0)
        }
    }

    @Test func userFieldsAreNamedInFinalOrder() {
        let l = UniformLayoutBuilder.build([(path("a"), .float), (path("b"), .float4)])
        #expect(l.field(for: path("b"))?.name == "p0")
        #expect(l.field(for: path("a"))?.name == "p1")
    }

    @Test func boolStoresAsInt() {
        let l = UniformLayoutBuilder.build([(path("flag"), .bool)])
        #expect(l.field(for: path("flag"))?.mslType == "int")
        #expect(l.field(for: path("flag"))?.type == .bool)
    }

    @Test func mslStructMatchesFieldOrder() {
        let l = UniformLayoutBuilder.build([(path("a"), .float)])
        let expected = """
        struct Uniforms {
            float2 resolution;
            float2 mouse;
            float time;
            float p0;
        };
        """
        #expect(l.mslStruct == expected)
    }

    @Test func sortIsStableWithinAnAlignmentClass() {
        let l = UniformLayoutBuilder.build([(path("x"), .float), (path("y"), .int), (path("z"), .float)])
        #expect(l.fields.filter { $0.path != nil }.map(\.path!.param) == ["x", "y", "z"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter UniformLayoutTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'UniformLayoutBuilder' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// Identifies one uniform-backed value: a node instance path plus a socket/param name.
public struct ParamPath: Hashable, Sendable, Codable {
    public var instancePath: [NodeID]
    public var param: ParamID
    public init(node: NodeID, param: ParamID) { instancePath = [node]; self.param = param }
    public init(instancePath: [NodeID], param: ParamID) { self.instancePath = instancePath; self.param = param }
}

public struct UniformField: Sendable, Hashable {
    public let name: String
    public let mslType: String
    public let offset: Int
    public let size: Int
    public let type: SocketType
    public let path: ParamPath?
}

public struct UniformLayout: Sendable, Hashable {
    public static let reservedNames = ["resolution", "mouse", "time"]

    public let fields: [UniformField]
    public let totalSize: Int
    private let byPath: [ParamPath: Int]

    init(fields: [UniformField], totalSize: Int) {
        self.fields = fields
        self.totalSize = totalSize
        var m: [ParamPath: Int] = [:]
        for (i, f) in fields.enumerated() { if let p = f.path { m[p] = i } }
        byPath = m
    }

    public func field(for path: ParamPath) -> UniformField? { byPath[path].map { fields[$0] } }

    public func reserved(_ name: String) -> UniformField {
        guard let f = fields.first(where: { $0.path == nil && $0.name == name }) else {
            preconditionFailure("unknown reserved uniform \(name)")
        }
        return f
    }

    public var mslStruct: String {
        var s = "struct Uniforms {\n"
        for f in fields { s += "    \(f.mslType) \(f.name);\n" }
        s += "};\n"
        return s
    }
}

public enum UniformLayoutBuilder {
    public static func build(_ requests: [(path: ParamPath, type: SocketType)]) -> UniformLayout {
        struct Pending { let path: ParamPath?; let name: String?; let type: SocketType }
        var pending: [Pending] = [
            Pending(path: nil, name: "resolution", type: .float2),
            Pending(path: nil, name: "mouse", type: .float2),
            Pending(path: nil, name: "time", type: .float),
        ]
        pending += requests.filter { $0.type.isUniformable }.map { Pending(path: $0.path, name: nil, type: $0.type) }

        // Stable sort, alignment descending.
        let sorted = pending.enumerated()
            .sorted { (a, b) in
                let aa = a.element.type.alignment ?? 0, ba = b.element.type.alignment ?? 0
                return aa != ba ? aa > ba : a.offset < b.offset
            }
            .map(\.element)

        var fields: [UniformField] = []
        var cursor = 0
        var userIndex = 0
        for p in sorted {
            let size = p.type.byteSize ?? 0, align = p.type.alignment ?? 1
            cursor = (cursor + align - 1) / align * align
            let name = p.name ?? "p\(userIndex)"
            if p.name == nil { userIndex += 1 }
            fields.append(UniformField(name: name, mslType: p.type.uniformStorageName ?? p.type.mslName,
                                       offset: cursor, size: size, type: p.type, path: p.path))
            cursor += size
        }
        let total = max(16, (cursor + 15) / 16 * 16)
        return UniformLayout(fields: fields, totalSize: total)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter UniformLayoutTests 2>&1 | tail -3`
Expected: all UniformLayoutTests pass.

- [ ] **Step 5: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): alignment-sorted uniform buffer layout

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 12: Emitter, LineMap and ShaderGenerator

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/LineMap.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ShaderGeneratorTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 3–11.
- Produces:
  - `struct LineMap: Sendable, Hashable { struct Entry { range: ClosedRange<Int>; node: NodeID }; var entries: [Entry]; func node(forLine: Int) -> NodeID?; func lines(for: NodeID) -> [ClosedRange<Int>] }` — 1-based lines into `GeneratedShader.source`.
  - `struct GeneratedShader: Sendable, Hashable { let source: String; let layout: UniformLayout; let lineMap: LineMap; let resolved: [NodeID: ResolvedNode]; let fragmentFunctionName: String; let target: OutputTarget }`
  - `enum ShaderGenerator { static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment, registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader }` and `static func diagnostics(_ doc: ShaderDocument, target:, registry:) -> [Diagnostic]` (validation + type errors, never throws).
  - `enum Emitter` (internal) — `emit(order:graph:registry:resolved:layout:) -> (lines: [String], lineMap: [(Int, NodeID)])`.

Emission rules:
1. For each node in topo order, each output socket gets `let`-style SSA: the emitter pre-declares `<msl> vN;` then appends the substituted body. Variable names `v0, v1, …` are numbered in emission order across all sockets.
2. `{in.x}`: if wired, the source variable, wrapped by `Conversion.apply` when types differ (the wrapped expression is used inline, no extra variable). If unwired: `.value` → the uniform field expression (`u.pN`, or `bool(u.pN)` for bool); `.uv` → `in.uv`; `.required` is impossible here (validation).
3. `{param.x}`: value params → uniform expression; enum params never appear in templates (they select variants). `{type.T}` → resolved MSL name.
4. Uniform slots are requested **only** for unwired inputs and value params that the chosen body actually references, in topo order, socket order — so unused inputs of a unary `Math` op allocate nothing.
5. `output.fragment`'s template is emitted verbatim as the last statement of `shaderMain` (it contains `return`).
6. Source layout, top to bottom: header, `Uniforms` struct, `VertexOut` struct, stdlib functions, `shaderMain`. Every line inside `shaderMain` that came from a node is recorded in the line map.

- [ ] **Step 1: Write the failing golden test**

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ShaderGeneratorTests {
    /// UV → Separate → Combine(x, y, 0.5-default) → Output. Deterministic IDs so the golden is stable.
    private func smallDocument() -> (ShaderDocument, uv: NodeID, sep: NodeID, comb: NodeID, out: NodeID) {
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
        return (d, uv.id, sep.id, comb.id, out.id)
    }

    @Test func goldenSource() throws {
        let (doc, _, _, _, _) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
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

        fragment float4 shaderMain(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]]) {
            float2 v0;
            v0 = in.uv;
            float v1;
            float v2;
            float v3;
            v1 = float3(v0, 0.0).x;
            v2 = float3(v0, 0.0).y;
            v3 = float3(v0, 0.0).z;
            float3 v4;
            v4 = float3(v1, v2, u.p0);
            return float4(v4, 1.0);
        }

        """
        #expect(shader.source == expected)
        #expect(shader.fragmentFunctionName == "shaderMain")
    }

    @Test func lineMapPointsAtNodes() throws {
        let (doc, uv, sep, comb, out) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
        let lines = shader.source.components(separatedBy: "\n")
        func line(containing s: String) -> Int { lines.firstIndex { $0.contains(s) }! + 1 }
        #expect(shader.lineMap.node(forLine: line(containing: "v0 = in.uv;")) == uv)
        #expect(shader.lineMap.node(forLine: line(containing: "v2 = float3(v0, 0.0).y;")) == sep)
        #expect(shader.lineMap.node(forLine: line(containing: "v4 = float3(v1, v2, u.p0);")) == comb)
        #expect(shader.lineMap.node(forLine: line(containing: "return float4(v4, 1.0);")) == out)
        #expect(shader.lineMap.node(forLine: 1) == nil)
    }

    @Test func layoutOnlyContainsReferencedSlots() throws {
        let (doc, _, _, comb, _) = smallDocument()
        let shader = try ShaderGenerator.generate(doc)
        let user = shader.layout.fields.compactMap(\.path)
        #expect(user == [ParamPath(node: comb, param: "z")])
    }

    @Test func unaryMathAllocatesNoSlotForUnusedInput() throws {
        var doc = ShaderDocument()
        let m = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("sine")])
        let out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[m.id] = m; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(m.id, "out"), to: SocketRef(out.id, "color"))
        let shader = try ShaderGenerator.generate(doc)
        #expect(shader.layout.fields.compactMap(\.path).map(\.param) == ["a"])
        #expect(shader.source.contains("v0 = sin(u.p0);"))
    }

    @Test func stdlibFunctionsAreIncludedOnceInDependencyOrder() throws {
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        let src = shader.source
        #expect(src.components(separatedBy: "float mn_hash21(").count == 2)
        #expect(src.components(separatedBy: "float mn_valueNoise(").count == 2)
        #expect(src.range(of: "mn_hash21(float2 p)")!.lowerBound < src.range(of: "mn_valueNoise(float2 p)")!.lowerBound)
    }

    @Test func sampleDocumentUsesTypePlaceholderAndVariants() throws {
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        #expect(shader.source.contains("mix("))
        #expect(shader.source.contains("sin("))
        #expect(shader.layout.fields.filter { $0.path != nil }.count == 3)   // speed.value, noise.scale, tint.value
        #expect(shader.layout.fields.first?.mslType == "float4")            // tint sorted first (16-byte)
    }

    @Test func boolUniformIsCastOnRead() throws {
        let def = NodeDef(id: "t.flag", title: "Flag", category: .utility,
                          inputs: [SocketDecl(name: "on", type: .concrete(.bool), default: .value(.bool(true)))],
                          outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                          body: .template("{out.out} = {in.on} ? 1.0 : 0.0;"))
        let reg = try NodeRegistry(BuiltinNodes.all + [def])
        var doc = ShaderDocument()
        let f = NodeInstance(kind: .builtin("t.flag")), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[f.id] = f; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(out.id, "color"))
        let shader = try ShaderGenerator.generate(doc, registry: reg)
        #expect(shader.source.contains("v0 = bool(u.p0) ? 1.0 : 0.0;"))
    }

    @Test func invalidGraphThrowsDiagnostics() {
        let doc = ShaderDocument()   // no output node
        #expect(throws: GenerationError.self) { try ShaderGenerator.generate(doc) }
        #expect(!ShaderGenerator.diagnostics(doc, target: .fragment, registry: .builtin).isEmpty)
    }

    @Test func generationIsDeterministic() throws {
        let a = try ShaderGenerator.generate(ShaderDocument.sample())
        let b = try ShaderGenerator.generate(ShaderDocument.sample())
        // sample() makes fresh IDs each call, so compare shape rather than bytes:
        #expect(a.source.count == b.source.count)
        #expect(a.layout.fields.map(\.mslType) == b.layout.fields.map(\.mslType))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ShaderGeneratorTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'ShaderGenerator' in scope`.

- [ ] **Step 3: Write `LineMap.swift`**

```swift
import Foundation

/// Maps 1-based lines of generated source back to the node that produced them (spec §9.4).
public struct LineMap: Sendable, Hashable {
    public struct Entry: Sendable, Hashable {
        public let range: ClosedRange<Int>
        public let node: NodeID
    }
    public var entries: [Entry] = []

    public init(entries: [Entry] = []) { self.entries = entries }

    public func node(forLine line: Int) -> NodeID? {
        entries.first { $0.range.contains(line) }?.node
    }

    public func lines(for node: NodeID) -> [ClosedRange<Int>] {
        entries.filter { $0.node == node }.map(\.range)
    }
}
```

- [ ] **Step 4: Write `Emitter.swift`**

```swift
import Foundation

/// Turns resolved nodes into SSA statements. Internal; `ShaderGenerator` is the API.
enum Emitter {
    struct Output {
        var bodyLines: [String] = []            // statements inside shaderMain, unindented
        var lineOwners: [NodeID?] = []          // parallel to bodyLines
        var layout: UniformLayout
        var requiredStdlib: [String] = []
    }

    /// Which `{in.x}` / `{param.x}` names a body references (rule 4).
    static func referencedNames(in body: NodeBody, chosen: String?) -> (inputs: Set<String>, params: Set<String>) {
        let text: String
        switch body {
        case .template(let t): text = t
        case .variants(_, let table): text = chosen.flatMap { table[$0] } ?? ""
        case .custom: return (inputs: [], params: [])
        }
        var ins = Set<String>(), ps = Set<String>()
        for m in text.matches(of: NodeRegistry.placeholderPattern) {
            if m.1 == "in" { ins.insert(String(m.2)) } else if m.1 == "param" { ps.insert(String(m.2)) }
        }
        return (ins, ps)
    }

    static func chosenVariant(_ def: NodeDef, _ inst: NodeInstance) -> String? {
        guard case .variants(let param, _) = def.body else { return nil }
        if case .enumCase(let c)? = inst.params[param] { return c }
        if case .enumCase(let c) = def.param(named: param)!.defaultValue { return c }
        return nil
    }

    static func emit(order: [NodeID], graph: Graph, registry: NodeRegistry,
                     resolved: [NodeID: ResolvedNode]) -> Output {
        // Pass 1: collect uniform requests in a deterministic order.
        var requests: [(path: ParamPath, type: SocketType)] = []
        for id in order {
            guard let inst = graph.nodes[id], case .builtin(let defID) = inst.kind,
                  let def = registry[defID], let r = resolved[id] else { continue }
            let refs = referencedNames(in: def.body, chosen: chosenVariant(def, inst))
            let custom: Bool = { if case .custom = def.body { return true } else { return false } }()
            for decl in def.inputs where (custom || refs.inputs.contains(decl.name)) {
                if graph.inputs[SocketRef(id, decl.name)] != nil { continue }
                if case .value = decl.default { requests.append((ParamPath(node: id, param: decl.name), r.inputTypes[decl.name]!)) }
            }
            for p in def.params where (custom || refs.params.contains(p.name)) {
                if case .value(let t, _) = p.kind { requests.append((ParamPath(node: id, param: p.name), t)) }
            }
        }
        var out = Output(layout: UniformLayoutBuilder.build(requests))

        func uniformExpr(_ path: ParamPath) -> String {
            let f = out.layout.field(for: path)!
            return f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)"
        }

        // Pass 2: statements.
        var varCounter = 0
        var outputVars: [SocketRef: String] = [:]
        for id in order {
            guard let inst = graph.nodes[id], case .builtin(let defID) = inst.kind,
                  let def = registry[defID], let r = resolved[id] else { continue }
            out.requiredStdlib += def.requires

            // Declare outputs.
            var outputs: [String: String] = [:]
            for decl in def.outputs {
                let name = "v\(varCounter)"; varCounter += 1
                outputs[decl.name] = name
                outputVars[SocketRef(id, decl.name)] = name
                out.bodyLines.append("\(r.outputTypes[decl.name]!.mslName) \(name);")
                out.lineOwners.append(id)
            }

            // Input expressions.
            var inputs: [String: String] = [:]
            for decl in def.inputs {
                let dst = r.inputTypes[decl.name]!
                if let src = graph.inputs[SocketRef(id, decl.name)], let v = outputVars[src],
                   let srcType = resolved[src.node]?.outputTypes[src.socket] {
                    inputs[decl.name] = ConversionRules.convert(from: srcType, to: dst)!.apply(v)
                } else {
                    switch decl.default {
                    case .uv: inputs[decl.name] = "in.uv"
                    case .value:
                        let path = ParamPath(node: id, param: decl.name)
                        if out.layout.field(for: path) != nil { inputs[decl.name] = uniformExpr(path) }
                    case .required: inputs[decl.name] = "/* unconnected */"
                    }
                }
            }
            var params: [String: String] = [:], enums: [String: String] = [:]
            for p in def.params {
                switch p.kind {
                case .value: if out.layout.field(for: ParamPath(node: id, param: p.name)) != nil { params[p.name] = uniformExpr(ParamPath(node: id, param: p.name)) }
                case .enumeration:
                    if case .enumCase(let c)? = inst.params[p.name] { enums[p.name] = c }
                    else if case .enumCase(let c) = p.defaultValue { enums[p.name] = c }
                case .asset: break
                }
            }
            let ctx = EmitContext(inputs: inputs, outputs: outputs, params: params, enums: enums, types: r.generics)

            let lines: [String]
            switch def.body {
            case .template(let t): lines = substitute(t, ctx)
            case .variants(let param, let table): lines = substitute(table[enums[param]!]!, ctx)
            case .custom(let f): lines = f(ctx)
            }
            for l in lines { out.bodyLines.append(l); out.lineOwners.append(id) }
        }
        return out
    }

    static func substitute(_ template: String, _ ctx: EmitContext) -> [String] {
        let replaced = template.replacing(NodeRegistry.placeholderPattern) { m -> String in
            let name = String(m.2)
            switch m.1 {
            case "in": return ctx.inputs[name] ?? "/* ?in.\(name) */"
            case "out": return ctx.outputs[name] ?? "/* ?out.\(name) */"
            case "param": return ctx.params[name] ?? "/* ?param.\(name) */"
            case "type": return ctx.types[name]?.mslName ?? "float"
            default: return String(m.0)
            }
        }
        return replaced.components(separatedBy: "\n")
    }
}
```

- [ ] **Step 5: Write `ShaderGenerator.swift`**

```swift
import Foundation

public struct GeneratedShader: Sendable, Hashable {
    public let source: String
    public let layout: UniformLayout
    public let lineMap: LineMap
    public let resolved: [NodeID: ResolvedNode]
    public let fragmentFunctionName: String
    public let target: OutputTarget
}

public enum ShaderGenerator {
    public static let fragmentFunctionName = "shaderMain"

    /// Validation and type diagnostics without generating. Never throws.
    public static func diagnostics(_ doc: ShaderDocument, target: OutputTarget, registry: NodeRegistry) -> [Diagnostic] {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { return structural }
        guard let terminal = GraphValidator.terminal(in: doc.root) else { return structural }
        let order = TopoSort.order(doc.root, from: terminal)
        return structural + TypeResolver.resolve(doc.root, registry: registry, order: order).diagnostics
    }

    public static func generate(_ doc: ShaderDocument, target: OutputTarget = .fragment,
                                registry: NodeRegistry = .builtin) throws(GenerationError) -> GeneratedShader {
        let structural = GraphValidator.validate(doc.root, registry: registry, target: target)
        if structural.contains(where: { $0.severity == .error }) { throw .invalid(structural) }
        let terminal = GraphValidator.terminal(in: doc.root)!
        let order = TopoSort.order(doc.root, from: terminal)
        let (resolved, typeDiags) = TypeResolver.resolve(doc.root, registry: registry, order: order)
        if !typeDiags.isEmpty { throw .invalid(structural + typeDiags) }

        let emitted = Emitter.emit(order: order, graph: doc.root, registry: registry, resolved: resolved)

        var src = ""
        src += "#include <metal_stdlib>\nusing namespace metal;\n\n"
        src += emitted.layout.mslStruct + "\n"
        src += "struct VertexOut {\n    float4 position [[position]];\n    float2 uv;\n};\n\n"
        for f in MSLStdlib.resolve(emitted.requiredStdlib) { src += f.source + "\n\n" }
        src += "fragment float4 \(fragmentFunctionName)(VertexOut in [[stage_in]],\n"
        src += "                           constant Uniforms &u [[buffer(0)]]) {\n"
        let bodyStart = src.components(separatedBy: "\n").count   // 1-based line of first body line
        var map = LineMap()
        for (i, line) in emitted.bodyLines.enumerated() {
            src += "    " + line + "\n"
            if let owner = emitted.lineOwners[i] {
                let n = bodyStart + i
                if let last = map.entries.last, last.node == owner, last.range.upperBound == n - 1 {
                    map.entries[map.entries.count - 1] = LineMap.Entry(range: last.range.lowerBound...n, node: owner)
                } else {
                    map.entries.append(LineMap.Entry(range: n...n, node: owner))
                }
            }
        }
        src += "}\n"
        return GeneratedShader(source: src, layout: emitted.layout, lineMap: map, resolved: resolved,
                               fragmentFunctionName: fragmentFunctionName, target: target)
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter ShaderGeneratorTests 2>&1 | tail -5`
Expected: all ShaderGeneratorTests pass. If `goldenSource` fails only on whitespace, print `shader.source` and align the golden — the golden is the *contract*, so fix the emitter, not the test, unless the difference is a genuine formatting preference.

- [ ] **Step 7: Run the full core suite**

Run: `swift test --package-path MetalNodesKit 2>&1 | tail -3`
Expected: every test passes.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(core): SSA emitter, line map and ShaderGenerator with golden tests

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 13: Static vertex stage and the ShaderCompiler actor

**Files:**
- Delete: `MetalNodesKit/Sources/MetalNodesRender/Placeholder.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/VertexStage.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiler.swift`
- Delete: `MetalNodesKit/Tests/MetalNodesRenderTests/Placeholder.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift`

**Interfaces:**
- Consumes: `GeneratedShader`, `ShaderGenerator`, `NodeRegistry.builtin`.
- Produces:
  - `enum VertexStage { static let functionName = "mn_fullscreenVertex"; static let source: String }` — compiled **once** per compiler; never regenerated (spec §9.1).
  - `struct CompiledPipeline: @unchecked Sendable { let state: MTLRenderPipelineState; let shader: GeneratedShader; let generation: UInt64 }`
  - `enum CompileResult: Sendable { case success(CompiledPipeline), failure(message: String, lines: [CompileLine], generation: UInt64), superseded(generation: UInt64) }`, `struct CompileLine: Sendable, Hashable { let line: Int; let message: String }`
  - `actor ShaderCompiler { init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws; func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult; var cacheCount: Int; static func parseLines(_ message: String) -> [CompileLine] }`

Generation rule (spec §9.6): the compiler remembers the highest generation ever requested. A finished job whose generation is lower than that returns `.superseded` instead of a pipeline, so a slow old compile can never be published over a newer one.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Metal
import MetalNodesCore
@testable import MetalNodesRender

@Suite struct ShaderCompilerTests {
    static let device = MTLCreateSystemDefaultDevice()

    private func compiler() throws -> ShaderCompiler {
        let d = try #require(Self.device, "No Metal device — these tests need a GPU")
        return try ShaderCompiler(device: d)
    }

    @Test func sampleDocumentCompiles() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        guard case .success(let p) = await c.compile(shader, generation: 1) else {
            Issue.record("expected success"); return
        }
        #expect(p.generation == 1)
        #expect(p.shader == shader)
    }

    @Test func everyBuiltinNodeCompilesAsAOneNodeGraph() async throws {
        let c = try compiler()
        for def in NodeRegistry.builtin.all where def.id != "output.fragment" {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin(def.id))
            let out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            if let first = def.outputs.first {
                doc.root.connect(SocketRef(n.id, first.name), to: SocketRef(out.id, "color"))
            }
            let shader = try ShaderGenerator.generate(doc)
            let result = await c.compile(shader, generation: 1)
            if case .failure(let msg, _, _) = result { Issue.record("\(def.id) failed: \(msg)\n\(shader.source)") }
        }
    }

    @Test func everyMathVariantCompiles() async throws {
        let c = try compiler()
        let def = NodeRegistry.builtin["math.math"]!
        guard case .variants(_, let table) = def.body else { return }
        for op in table.keys.sorted() {
            var doc = ShaderDocument()
            let n = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase(op)])
            let out = NodeInstance(kind: .builtin("output.fragment"))
            doc.root.nodes[n.id] = n; doc.root.nodes[out.id] = out
            doc.root.connect(SocketRef(n.id, "out"), to: SocketRef(out.id, "color"))
            if case .failure(let msg, _, _) = await c.compile(try ShaderGenerator.generate(doc), generation: 1) {
                Issue.record("math.\(op) failed: \(msg)")
            }
        }
    }

    @Test func olderGenerationIsSuperseded() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 2)
        guard case .superseded(let g) = await c.compile(shader, generation: 1) else {
            Issue.record("expected superseded"); return
        }
        #expect(g == 1)
    }

    @Test func identicalSourceHitsTheCache() async throws {
        let c = try compiler()
        let shader = try ShaderGenerator.generate(ShaderDocument.sample())
        _ = await c.compile(shader, generation: 1)
        _ = await c.compile(shader, generation: 2)
        #expect(await c.cacheCount == 1)
    }

    @Test func brokenSourceReportsFailureWithLine() async throws {
        let c = try compiler()
        var shader = try ShaderGenerator.generate(ShaderDocument.sample())
        shader = GeneratedShader(source: shader.source.replacingOccurrences(of: "return", with: "retrun"),
                                 layout: shader.layout, lineMap: shader.lineMap, resolved: shader.resolved,
                                 fragmentFunctionName: shader.fragmentFunctionName, target: shader.target)
        guard case .failure(_, let lines, _) = await c.compile(shader, generation: 1) else {
            Issue.record("expected failure"); return
        }
        #expect(!lines.isEmpty)
        #expect(lines.first!.line > 1)
    }

    @Test func parsesClangStyleLines() {
        let msg = "program_source:42:9: error: use of undeclared identifier 'retrun'\nprogram_source:50:1: warning: unused"
        let lines = ShaderCompiler.parseLines(msg)
        #expect(lines == [CompileLine(line: 42, message: "use of undeclared identifier 'retrun'"),
                          CompileLine(line: 50, message: "unused")])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'ShaderCompiler' in scope`.

- [ ] **Step 3: Write `VertexStage.swift`**

```swift
import Foundation

/// The fullscreen-triangle vertex stage. Static: compiled once, never regenerated.
/// `uv` is 0…1 with the origin **bottom-left** (spec §9.1).
public enum VertexStage {
    public static let functionName = "mn_fullscreenVertex"

    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    vertex VertexOut mn_fullscreenVertex(uint vid [[vertex_id]]) {
        float2 pos = float2((vid == 2) ? 3.0 : -1.0, (vid == 1) ? 3.0 : -1.0);
        VertexOut o;
        o.position = float4(pos, 0.0, 1.0);
        o.uv = pos * 0.5 + 0.5;
        return o;
    }
    """
}
```

- [ ] **Step 4: Write `ShaderCompiler.swift`**

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

public struct CompileLine: Sendable, Hashable {
    public let line: Int
    public let message: String
    public init(line: Int, message: String) { self.line = line; self.message = message }
}

public enum CompileResult: Sendable {
    case success(CompiledPipeline)
    case failure(message: String, lines: [CompileLine], generation: UInt64)
    case superseded(generation: UInt64)
}

public enum ShaderCompilerError: Error { case vertexFunctionMissing, fragmentFunctionMissing }

/// Compiles generated MSL off the main actor. Caches by source; latest generation wins (spec §9.6, §10).
public actor ShaderCompiler {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let pixelFormat: MTLPixelFormat
    private var cache: [String: MTLRenderPipelineState] = [:]
    private var latestRequested: UInt64 = 0

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.pixelFormat = pixelFormat
        let lib = try device.makeLibrary(source: VertexStage.source, options: nil)
        guard let fn = lib.makeFunction(name: VertexStage.functionName) else { throw ShaderCompilerError.vertexFunctionMissing }
        vertexFunction = fn
    }

    public var cacheCount: Int { cache.count }

    public func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult {
        latestRequested = max(latestRequested, generation)

        if let hit = cache[shader.source] {
            return finish(hit, shader, generation)
        }
        do {
            let options = MTLCompileOptions()
            options.mathMode = .fast
            let lib = try await device.makeLibrary(source: shader.source, options: options)
            guard let frag = lib.makeFunction(name: shader.fragmentFunctionName) else {
                throw ShaderCompilerError.fragmentFunctionMissing
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertexFunction
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let state = try device.makeRenderPipelineState(descriptor: desc)
            cache[shader.source] = state
            return finish(state, shader, generation)
        } catch {
            let msg = error.localizedDescription
            return .failure(message: msg, lines: ShaderCompiler.parseLines(msg), generation: generation)
        }
    }

    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        generation < latestRequested
            ? .superseded(generation: generation)
            : .success(CompiledPipeline(state: state, shader: shader, generation: generation))
    }

    /// Pulls `program_source:LINE:COL: (error|warning): message` entries out of a Metal compiler message.
    public static func parseLines(_ message: String) -> [CompileLine] {
        let pattern = /program_source:(\d+):\d+:\s*(?:error|warning|note):\s*([^\n]*)/
        return message.matches(of: pattern).compactMap { m in
            Int(m.1).map { CompileLine(line: $0, message: String(m.2).trimmingCharacters(in: .whitespaces)) }
        }
    }
}
```

If `MTLCompileOptions.mathMode` is unavailable on the installed SDK, use `options.fastMathEnabled = true` instead.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests 2>&1 | tail -5`
Expected: all ShaderCompilerTests pass. `everyBuiltinNodeCompilesAsAOneNodeGraph` failing for one node means that node's MSL template is wrong — fix the template in `BuiltinNodes.swift`, never the test.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(render): static vertex stage and ShaderCompiler actor with generation guard

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 14: UniformImage, UniformRing, ShaderRenderer and PreviewView

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/UniformImage.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/UniformRing.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/PreviewView.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/UniformImageTests.swift`

**Interfaces:**
- Consumes: `UniformLayout`, `ParamPath`, `ParamValue`, `ShaderDocument`, `NodeRegistry`, `CompiledPipeline`.
- Produces:
  - `struct UniformImage: Sendable, Equatable { let layout: UniformLayout; private(set) var bytes: [UInt8]; init(layout:); @discardableResult mutating func set(_ value: ParamValue, for path: ParamPath) -> Bool; mutating func setReserved(time: Float, resolution: SIMD2<Float>, mouse: SIMD2<Float>); static func rebuild(layout: UniformLayout, document: ShaderDocument, registry: NodeRegistry) -> UniformImage }`
  - `@MainActor final class UniformRing { init(device: MTLDevice, size: Int, count: Int = 3); func next() -> MTLBuffer }`
  - `@MainActor @Observable final class PreviewState { var pipeline: CompiledPipeline?; var uniforms: UniformImage?; var isPlaying: Bool; var timeOffset: Float; var mouse: SIMD2<Float>; var drawableSize: CGSize; var lastError: String? }`
  - `@MainActor final class ShaderRenderer: NSObject, MTKViewDelegate { init(device: MTLDevice, state: PreviewState) }`
  - `struct PreviewView: View { init(state: PreviewState, device: MTLDevice) }`

Coercion rule for `UniformImage.set`: the stored value is converted to the field's type — scalars splat into vectors, vectors truncate or zero-pad (`w = 1` when padding to four), `int`/`bool` fields take the first component rounded / `!= 0`. This is what lets a `float` default on a generic input feed a resolved `float3` slot.

Rebuild rule (spec §9.6 #3): on every pipeline publish the UI calls `UniformImage.rebuild(...)` for the new layout — the document is the source of truth, the buffer is a projection.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import MetalNodesCore
@testable import MetalNodesRender

@Suite struct UniformImageTests {
    let n = NodeID()
    func path(_ p: String) -> ParamPath { ParamPath(node: n, param: p) }

    func readFloat(_ img: UniformImage, _ offset: Int) -> Float {
        img.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Float.self) }
    }
    func readInt(_ img: UniformImage, _ offset: Int) -> Int32 {
        img.bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
    }

    @Test func writesFloatAtFieldOffset() {
        let layout = UniformLayoutBuilder.build([(path("a"), .float)])
        var img = UniformImage(layout: layout)
        #expect(img.set(.float(0.75), for: path("a")))
        #expect(readFloat(img, layout.field(for: path("a"))!.offset) == 0.75)
        #expect(img.bytes.count == layout.totalSize)
    }

    @Test func scalarSplatsIntoFloat3Field() {
        let layout = UniformLayoutBuilder.build([(path("v"), .float3)])
        var img = UniformImage(layout: layout)
        img.set(.float(2), for: path("v"))
        let o = layout.field(for: path("v"))!.offset
        #expect(readFloat(img, o) == 2 && readFloat(img, o + 4) == 2 && readFloat(img, o + 8) == 2)
    }

    @Test func float3PadsToFloat4WithAlphaOne() {
        let layout = UniformLayoutBuilder.build([(path("c"), .color)])
        var img = UniformImage(layout: layout)
        img.set(.float3(.init(0.1, 0.2, 0.3)), for: path("c"))
        let o = layout.field(for: path("c"))!.offset
        #expect(readFloat(img, o + 12) == 1)
    }

    @Test func boolWritesInt() {
        let layout = UniformLayoutBuilder.build([(path("b"), .bool)])
        var img = UniformImage(layout: layout)
        img.set(.bool(true), for: path("b"))
        #expect(readInt(img, layout.field(for: path("b"))!.offset) == 1)
        img.set(.float(0), for: path("b"))
        #expect(readInt(img, layout.field(for: path("b"))!.offset) == 0)
    }

    @Test func unknownPathReturnsFalse() {
        var img = UniformImage(layout: UniformLayoutBuilder.build([]))
        #expect(img.set(.float(1), for: path("nope")) == false)
    }

    @Test func reservedFieldsAreWritten() {
        let layout = UniformLayoutBuilder.build([])
        var img = UniformImage(layout: layout)
        img.setReserved(time: 3.5, resolution: .init(640, 480), mouse: .init(1, 2))
        #expect(readFloat(img, layout.reserved("time").offset) == 3.5)
        #expect(readFloat(img, layout.reserved("resolution").offset + 4) == 480)
        #expect(readFloat(img, layout.reserved("mouse").offset) == 1)
    }

    @Test func rebuildReadsDocumentValuesAndDefaults() throws {
        let doc = ShaderDocument.sample()
        let shader = try ShaderGenerator.generate(doc)
        let img = UniformImage.rebuild(layout: shader.layout, document: doc, registry: .builtin)
        let speed = doc.root.nodes.values.first { $0.kind == .builtin("input.float") }!
        let noise = doc.root.nodes.values.first { $0.kind == .builtin("noise.value") }!
        let tint = doc.root.nodes.values.first { $0.kind == .builtin("input.color") }!
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: speed.id, param: "value"))!.offset) == 0.25)
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: noise.id, param: "scale"))!.offset) == 6)
        #expect(readFloat(img, shader.layout.field(for: ParamPath(node: tint.id, param: "value"))!.offset + 12) == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter UniformImageTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'UniformImage' in scope`.

- [ ] **Step 3: Write `UniformImage.swift`**

```swift
import Foundation
import MetalNodesCore

/// CPU-side bytes for one `Uniforms` struct. Copied into a GPU buffer every frame.
public struct UniformImage: Sendable, Equatable {
    public let layout: UniformLayout
    public private(set) var bytes: [UInt8]

    public init(layout: UniformLayout) {
        self.layout = layout
        bytes = [UInt8](repeating: 0, count: layout.totalSize)
    }

    @discardableResult
    public mutating func set(_ value: ParamValue, for path: ParamPath) -> Bool {
        guard let f = layout.field(for: path) else { return false }
        write(value, into: f)
        return true
    }

    public mutating func setReserved(time: Float, resolution: SIMD2<Float>, mouse: SIMD2<Float>) {
        write(.float(time), into: layout.reserved("time"))
        write(.float2(resolution), into: layout.reserved("resolution"))
        write(.float2(mouse), into: layout.reserved("mouse"))
    }

    /// Fresh image from the document: every field takes the instance's stored
    /// value, else the definition's default. Called on every pipeline publish.
    public static func rebuild(layout: UniformLayout, document: ShaderDocument, registry: NodeRegistry) -> UniformImage {
        var img = UniformImage(layout: layout)
        for f in layout.fields {
            guard let path = f.path, let nodeID = path.instancePath.first,
                  let inst = document.root.nodes[nodeID], case .builtin(let defID) = inst.kind,
                  let def = registry[defID] else { continue }
            if let v = inst.params[path.param] {
                img.write(v, into: f)
            } else if let decl = def.input(named: path.param), case .value(let v) = decl.default {
                img.write(v, into: f)
            } else if let p = def.param(named: path.param) {
                img.write(p.defaultValue, into: f)
            }
        }
        return img
    }

    // MARK: - Coercion

    private static func components(_ v: ParamValue) -> [Float] {
        switch v {
        case .float(let x): [x]
        case .float2(let s): [s.x, s.y]
        case .float3(let s): [s.x, s.y, s.z]
        case .float4(let s): [s.x, s.y, s.z, s.w]
        case .int(let i): [Float(i)]
        case .bool(let b): [b ? 1 : 0]
        case .enumCase, .asset: []
        }
    }

    private mutating func write(_ value: ParamValue, into f: UniformField) {
        let src = UniformImage.components(value)
        guard !src.isEmpty else { return }
        switch f.type {
        case .int:
            put(Int32(src[0].rounded()), at: f.offset)
        case .bool:
            put(Int32(src[0] != 0 ? 1 : 0), at: f.offset)
        case .float:
            put(src[0], at: f.offset)
        case .float2, .float3, .float4, .color:
            let n = f.type.componentCount ?? 1
            var out = [Float](repeating: 0, count: n)
            if src.count == 1 {
                out = [Float](repeating: src[0], count: n)
            } else {
                for i in 0..<n { out[i] = i < src.count ? src[i] : (i == 3 ? 1 : 0) }
            }
            for (i, x) in out.enumerated() { put(x, at: f.offset + i * 4) }
        case .texture:
            break
        }
    }

    private mutating func put<T>(_ x: T, at offset: Int) {
        withUnsafeBytes(of: x) { raw in
            for (i, b) in raw.enumerated() { bytes[offset + i] = b }
        }
    }
}
```

- [ ] **Step 4: Write `UniformRing.swift` and `PreviewState.swift`**

`UniformRing.swift`:

```swift
import Metal

/// Triple-buffered uniform storage so the CPU never writes a buffer the GPU is reading.
@MainActor
public final class UniformRing {
    private let buffers: [MTLBuffer]
    private var index = 0
    public let size: Int

    public init(device: MTLDevice, size: Int, count: Int = 3) {
        self.size = size
        buffers = (0..<count).map { i in
            let b = device.makeBuffer(length: max(size, 16), options: .storageModeShared)!
            b.label = "Uniforms[\(i)]"
            return b
        }
    }

    public func next() -> MTLBuffer {
        index = (index + 1) % buffers.count
        return buffers[index]
    }
}
```

`PreviewState.swift`:

```swift
import Foundation
import CoreGraphics
import Observation

/// Hand-off between the editor (writes) and the renderer (reads every frame).
@MainActor
@Observable
public final class PreviewState {
    public var pipeline: CompiledPipeline?
    public var uniforms: UniformImage?
    public var isPlaying = true
    /// Seconds subtracted from wall-clock so "reset time" is cheap.
    public var timeOffset: Float = 0
    public var mouse = SIMD2<Float>(0, 0)
    public var drawableSize = CGSize(width: 1, height: 1)
    public var lastError: String?

    public init() {}
}
```

- [ ] **Step 5: Write `ShaderRenderer.swift`**

```swift
import Foundation
import Metal
import MetalKit
import QuartzCore

/// Draws the current pipeline as a fullscreen triangle. Runs on the main actor —
/// `MTKView` calls its delegate on the main thread.
@MainActor
public final class ShaderRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let state: PreviewState
    private var ring: UniformRing?
    private let inflight = DispatchSemaphore(value: 3)
    private let startTime = CACurrentMediaTime()
    private var pausedAt: Float?

    public init(device: MTLDevice, state: PreviewState) {
        self.device = device
        self.queue = device.makeCommandQueue()!
        self.state = state
        super.init()
    }

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        state.drawableSize = size
    }

    public func draw(in view: MTKView) {
        guard let pipeline = state.pipeline, var image = state.uniforms,
              image.layout == pipeline.shader.layout,
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return }

        if ring == nil || ring!.size != image.layout.totalSize {
            ring = UniformRing(device: device, size: image.layout.totalSize)
        }

        // Time: wall clock while playing; frozen while paused.
        let now = Float(CACurrentMediaTime() - startTime)
        let t: Float
        if state.isPlaying { pausedAt = nil; t = now - state.timeOffset }
        else { if pausedAt == nil { pausedAt = now - state.timeOffset }; t = pausedAt! }

        image.setReserved(time: t,
                          resolution: SIMD2(Float(view.drawableSize.width), Float(view.drawableSize.height)),
                          mouse: state.mouse)

        inflight.wait()
        let buffer = ring!.next()
        image.bytes.withUnsafeBytes { buffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else {
            inflight.signal(); return
        }
        enc.setRenderPipelineState(pipeline.state)
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        let sem = inflight
        cmd.addCompletedHandler { _ in sem.signal() }
        cmd.present(drawable)
        cmd.commit()
    }
}
```

If the compiler rejects the `MTKViewDelegate` conformance under strict concurrency, change the declaration to `extension ShaderRenderer: @preconcurrency MTKViewDelegate` with the two methods moved into that extension.

- [ ] **Step 6: Write `PreviewView.swift`**

```swift
import SwiftUI
import MetalKit

/// SwiftUI wrapper around an `MTKView` driven by `ShaderRenderer`.
public struct PreviewView {
    private let state: PreviewState
    private let device: MTLDevice

    public init(state: PreviewState, device: MTLDevice) {
        self.state = state
        self.device = device
    }

    @MainActor
    private func makeView(_ renderer: ShaderRenderer) -> MTKView {
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 60
        v.isPaused = false
        v.enableSetNeedsDisplay = false
        v.framebufferOnly = true
        v.delegate = renderer
        return v
    }
}

#if canImport(AppKit)
extension PreviewView: NSViewRepresentable {
    public func makeCoordinator() -> ShaderRenderer { ShaderRenderer(device: device, state: state) }
    public func makeNSView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateNSView(_ view: MTKView, context: Context) {}
}
#else
extension PreviewView: UIViewRepresentable {
    public func makeCoordinator() -> ShaderRenderer { ShaderRenderer(device: device, state: state) }
    public func makeUIView(context: Context) -> MTKView { makeView(context.coordinator) }
    public func updateUIView(_ view: MTKView, context: Context) {}
}
#endif
```

- [ ] **Step 7: Run tests and build**

Run: `swift test --package-path MetalNodesKit --filter UniformImageTests 2>&1 | tail -3`
Expected: all UniformImageTests pass.

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|warning: .*concurrency|Compiling|Build complete' | tail -5`
Expected: `Build complete!` with no `error:` lines.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(render): uniform image/ring, MTKView renderer and PreviewView

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 15: Dracula theme tokens and CanvasTransform

**Files:**
- Delete: `MetalNodesKit/Sources/MetalNodesUI/Placeholder.swift`
- Delete: `MetalNodesKit/Tests/MetalNodesUITests/Placeholder.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Theme/DraculaTheme.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/CanvasTransform.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/DraculaThemeTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/CanvasTransformTests.swift`

**Interfaces:**
- Consumes: `NodeCategory`, `SocketType`, `DraculaAccent`, `Camera`.
- Produces:
  - `enum DraculaToken: CaseIterable, Sendable { background, surface, foreground, muted, cyan, green, orange, pink, purple, red, yellow; var hex: UInt32; var color: Color }`
  - `enum DraculaTheme { static func token(for: NodeCategory) -> DraculaToken; static func token(for: SocketType) -> DraculaToken; static func token(for: DraculaAccent) -> DraculaToken; static let selection: DraculaToken = .foreground; static let error: DraculaToken = .red; static let viewerFlag: DraculaToken = .green; static let wireDefault: DraculaToken = .muted }` plus `extension Color { init(hex: UInt32) }`.
  - `struct CanvasTransform: Equatable, Sendable { var pan: CGSize; var zoom: CGFloat; static let minZoom: CGFloat = 0.15; static let maxZoom: CGFloat = 4; init(camera: Camera); var camera: Camera; func toScreen(_: CGPoint) -> CGPoint; func toCanvas(_: CGPoint) -> CGPoint; mutating func zoom(by: CGFloat, around screenPoint: CGPoint); mutating func pan(by: CGSize); func visibleRect(viewport: CGSize) -> CGRect }`

Note: this removes the `EditorView` placeholder the app currently references; the app will not build again until Task 18. That is expected — `swift test` is the gate for Tasks 15–17.

- [ ] **Step 1: Write the failing tests**

`DraculaThemeTests.swift`:

```swift
import Testing
import SwiftUI
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct DraculaThemeTests {
    @Test func officialPaletteHexValues() {
        #expect(DraculaToken.background.hex == 0x282A36)
        #expect(DraculaToken.surface.hex == 0x44475A)
        #expect(DraculaToken.foreground.hex == 0xF8F8F2)
        #expect(DraculaToken.muted.hex == 0x6272A4)
        #expect(DraculaToken.cyan.hex == 0x8BE9FD)
        #expect(DraculaToken.green.hex == 0x50FA7B)
        #expect(DraculaToken.orange.hex == 0xFFB86C)
        #expect(DraculaToken.pink.hex == 0xFF79C6)
        #expect(DraculaToken.purple.hex == 0xBD93F9)
        #expect(DraculaToken.red.hex == 0xFF5555)
        #expect(DraculaToken.yellow.hex == 0xF1FA8C)
    }

    @Test func redIsReservedForErrors() {
        for c in NodeCategory.allCases { #expect(DraculaTheme.token(for: c) != .red) }
        for t in SocketType.allCases { #expect(DraculaTheme.token(for: t) != .red) }
        for a in DraculaAccent.allCases { #expect(DraculaTheme.token(for: a) != .red) }
        #expect(DraculaTheme.error == .red)
    }

    @Test func socketTypesMatchSpecTable() {
        #expect(DraculaTheme.token(for: SocketType.float) == .cyan)
        #expect(DraculaTheme.token(for: SocketType.float2) == .green)
        #expect(DraculaTheme.token(for: SocketType.float3) == .purple)
        #expect(DraculaTheme.token(for: SocketType.float4) == .pink)
        #expect(DraculaTheme.token(for: SocketType.color) == .yellow)
        #expect(DraculaTheme.token(for: SocketType.int) == .orange)
        #expect(DraculaTheme.token(for: SocketType.bool) == .muted)
        #expect(DraculaTheme.token(for: SocketType.texture) == .foreground)
    }

    @Test func categoriesMatchSpecTable() {
        #expect(DraculaTheme.token(for: NodeCategory.input) == .cyan)
        #expect(DraculaTheme.token(for: NodeCategory.math) == .purple)
        #expect(DraculaTheme.token(for: NodeCategory.vector) == .green)
        #expect(DraculaTheme.token(for: NodeCategory.sdf) == .orange)
        #expect(DraculaTheme.token(for: NodeCategory.noise) == .pink)
        #expect(DraculaTheme.token(for: NodeCategory.color) == .yellow)
        #expect(DraculaTheme.token(for: NodeCategory.utility) == .muted)
        #expect(DraculaTheme.token(for: NodeCategory.output) == .foreground)
    }
}
```

`CanvasTransformTests.swift`:

```swift
import Testing
import CoreGraphics
import MetalNodesCore
@testable import MetalNodesUI

@Suite struct CanvasTransformTests {
    @Test func screenCanvasRoundTrip() {
        let t = CanvasTransform(pan: CGSize(width: 100, height: -40), zoom: 2)
        let p = CGPoint(x: 37, y: 91)
        let back = t.toCanvas(t.toScreen(p))
        #expect(abs(back.x - p.x) < 1e-9 && abs(back.y - p.y) < 1e-9)
        #expect(t.toScreen(.zero) == CGPoint(x: 100, y: -40))
    }

    @Test func zoomAroundKeepsAnchorFixed() {
        var t = CanvasTransform(pan: CGSize(width: 10, height: 10), zoom: 1)
        let anchor = CGPoint(x: 200, y: 150)
        let canvasUnderAnchor = t.toCanvas(anchor)
        t.zoom(by: 1.5, around: anchor)
        let after = t.toCanvas(anchor)
        #expect(abs(after.x - canvasUnderAnchor.x) < 1e-9 && abs(after.y - canvasUnderAnchor.y) < 1e-9)
        #expect(t.zoom == 1.5)
    }

    @Test func zoomIsClamped() {
        var t = CanvasTransform(pan: .zero, zoom: 1)
        t.zoom(by: 100, around: .zero)
        #expect(t.zoom == CanvasTransform.maxZoom)
        t.zoom(by: 0.0001, around: .zero)
        #expect(t.zoom == CanvasTransform.minZoom)
    }

    @Test func visibleRectInCanvasSpace() {
        let t = CanvasTransform(pan: CGSize(width: -100, height: -50), zoom: 2)
        let r = t.visibleRect(viewport: CGSize(width: 800, height: 600))
        #expect(r == CGRect(x: 50, y: 25, width: 400, height: 300))
    }

    @Test func cameraRoundTrip() {
        let cam = Camera(pan: CGSize(width: 3, height: 4), zoom: 0.5)
        #expect(CanvasTransform(camera: cam).camera == cam)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter 'DraculaThemeTests|CanvasTransformTests' 2>&1 | tail -3`
Expected: compile errors, `cannot find 'DraculaToken'` / `cannot find 'CanvasTransform'`.

- [ ] **Step 3: Write `DraculaTheme.swift`**

```swift
import SwiftUI
import MetalNodesCore

/// The official Dracula palette. The only file allowed to contain hex literals.
public enum DraculaToken: CaseIterable, Sendable {
    case background, surface, foreground, muted
    case cyan, green, orange, pink, purple, red, yellow

    public var hex: UInt32 {
        switch self {
        case .background: 0x282A36
        case .surface:    0x44475A
        case .foreground: 0xF8F8F2
        case .muted:      0x6272A4
        case .cyan:       0x8BE9FD
        case .green:      0x50FA7B
        case .orange:     0xFFB86C
        case .pink:       0xFF79C6
        case .purple:     0xBD93F9
        case .red:        0xFF5555
        case .yellow:     0xF1FA8C
        }
    }

    public var color: Color { Color(hex: hex) }
}

public enum DraculaTheme {
    /// Red is reserved for errors and used for nothing else (spec §12).
    public static let error: DraculaToken = .red
    /// Selection is an outline, not a hue.
    public static let selection: DraculaToken = .foreground
    public static let viewerFlag: DraculaToken = .green
    public static let wireDefault: DraculaToken = .muted
    public static let canvasGrid: Color = DraculaToken.surface.color.opacity(0.55)

    public static func token(for category: NodeCategory) -> DraculaToken {
        switch category {
        case .input: .cyan
        case .math: .purple
        case .vector: .green
        case .sdf: .orange
        case .noise: .pink
        case .color: .yellow
        case .utility: .muted
        case .output: .foreground
        }
    }

    public static func token(for type: SocketType) -> DraculaToken {
        switch type {
        case .float: .cyan
        case .float2: .green
        case .float3: .purple
        case .float4: .pink
        case .color: .yellow
        case .int: .orange
        case .bool: .muted
        case .texture: .foreground
        }
    }

    public static func token(for accent: DraculaAccent) -> DraculaToken {
        switch accent {
        case .cyan: .cyan
        case .green: .green
        case .orange: .orange
        case .pink: .pink
        case .purple: .purple
        case .yellow: .yellow
        case .muted: .muted
        }
    }
}

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
```

- [ ] **Step 4: Write `CanvasTransform.swift`**

```swift
import CoreGraphics
import MetalNodesCore

/// Pan/zoom math for the node canvas. Screen = canvas × zoom + pan.
public struct CanvasTransform: Equatable, Sendable {
    public static let minZoom: CGFloat = 0.15
    public static let maxZoom: CGFloat = 4

    public var pan: CGSize
    public var zoom: CGFloat

    public init(pan: CGSize = .zero, zoom: CGFloat = 1) {
        self.pan = pan
        self.zoom = min(max(zoom, Self.minZoom), Self.maxZoom)
    }

    public init(camera: Camera) { self.init(pan: camera.pan, zoom: camera.zoom) }
    public var camera: Camera { Camera(pan: pan, zoom: zoom) }

    public func toScreen(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * zoom + pan.width, y: p.y * zoom + pan.height)
    }

    public func toCanvas(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - pan.width) / zoom, y: (p.y - pan.height) / zoom)
    }

    /// Multiplies zoom by `factor`, keeping the canvas point under `screenPoint` stationary.
    public mutating func zoom(by factor: CGFloat, around screenPoint: CGPoint) {
        let anchor = toCanvas(screenPoint)
        zoom = min(max(zoom * factor, Self.minZoom), Self.maxZoom)
        pan = CGSize(width: screenPoint.x - anchor.x * zoom, height: screenPoint.y - anchor.y * zoom)
    }

    public mutating func pan(by delta: CGSize) {
        pan.width += delta.width
        pan.height += delta.height
    }

    public func visibleRect(viewport: CGSize) -> CGRect {
        let origin = toCanvas(.zero)
        return CGRect(x: origin.x, y: origin.y, width: viewport.width / zoom, height: viewport.height / zoom)
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --package-path MetalNodesKit --filter 'DraculaThemeTests|CanvasTransformTests' 2>&1 | tail -3`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): Dracula theme tokens and canvas transform math

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 16: DocumentChange and EditorModel

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/DocumentChange.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiling.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/EditorModelTests.swift`

**Interfaces:**
- Consumes: `ShaderDocument`, `ShaderGenerator`, `GeneratedShader`, `UniformImage`, `PreviewState`, `CompileResult`, `CompileLine`, `ShaderCompiler`.
- Produces:
  - `protocol ShaderCompiling: Sendable { func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult }` with `extension ShaderCompiler: ShaderCompiling {}` (in MetalNodesRender).
  - `enum ChangeClass: Sendable { cosmetic, parameter, topology }`
  - `enum DocumentChange: Sendable { case moveNode(NodeID, to: CGPoint), setParam(NodeID, ParamID, ParamValue), connect(from: SocketRef, to: SocketRef), disconnect(SocketRef), addNode(NodeInstance), removeNode(NodeID); var changeClass: ChangeClass }`
  - `@MainActor @Observable final class EditorModel { init(document: ShaderDocument, compiler: any ShaderCompiling, registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState()); private(set) var document; var viewState: EditorViewState; let preview: PreviewState; let registry; private(set) var diagnostics: [Diagnostic]; private(set) var generatedSource: String; private(set) var resolvedTypes: [NodeID: ResolvedNode]; var debounceInterval: Duration; func apply(_ change: DocumentChange); func start(); func awaitIdle() async }`

Classification (spec §10): `moveNode` → cosmetic. `setParam` with a uniformable value → parameter (writes into `preview.uniforms` immediately, no compile); with `.enumCase` or `.asset` → topology. `connect`/`disconnect`/`addNode`/`removeNode` → topology (debounced compile). On a successful compile whose generation is still the latest, publish the pipeline **and rebuild the uniform image from the document**. On failure, keep the last-good pipeline, surface `lastError`, and map compiler lines back to nodes through the `LineMap` as diagnostics.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import MetalNodesCore
import MetalNodesRender
@testable import MetalNodesUI

/// Records generations and never publishes, so tests can count compiles deterministically.
actor RecordingCompiler: ShaderCompiling {
    private(set) var generations: [UInt64] = []
    func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult {
        generations.append(generation)
        return .superseded(generation: generation)
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
        #expect(DocumentChange.moveNode(id, to: .zero).changeClass == .cosmetic)
        #expect(DocumentChange.setParam(id, "value", .float(1)).changeClass == .parameter)
        #expect(DocumentChange.setParam(id, "op", .enumCase("sine")).changeClass == .topology)
        #expect(DocumentChange.connect(from: SocketRef(id, "a"), to: SocketRef(id, "b")).changeClass == .topology)
        #expect(DocumentChange.disconnect(SocketRef(id, "a")).changeClass == .topology)
        #expect(DocumentChange.removeNode(id).changeClass == .topology)
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
        m.apply(.moveNode(uv.id, to: CGPoint(x: 5, y: 5)))
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

    @Test func invalidGraphReportsDiagnosticsAndDoesNotCompile() async {
        let c = RecordingCompiler()
        let m = model(c)
        m.start(); await m.awaitIdle()
        m.apply(.removeNode(node(m, "output.fragment").id))
        await m.awaitIdle()
        #expect(m.diagnostics.contains { $0.message.contains("Fragment Output") })
        #expect(await c.generations == [1])
    }

    @Test func parameterChangeWritesUniformsWithoutRecompiling() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
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
        guard let device = MTLCreateSystemDefaultDevice() else { return }
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
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter EditorModelTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'EditorModel' in scope`.

- [ ] **Step 3: Write `ShaderCompiling.swift` (Render module)**

```swift
import MetalNodesCore

/// Abstracts `ShaderCompiler` so the editor can be tested without a GPU.
public protocol ShaderCompiling: Sendable {
    func compile(_ shader: GeneratedShader, generation: UInt64) async -> CompileResult
}

extension ShaderCompiler: ShaderCompiling {}
```

- [ ] **Step 4: Write `DocumentChange.swift`**

```swift
import CoreGraphics
import MetalNodesCore

public enum ChangeClass: Sendable { case cosmetic, parameter, topology }

/// Every edit goes through one of these, which is what makes classification
/// (spec §10) a `switch` instead of a diff.
public enum DocumentChange: Sendable {
    case moveNode(NodeID, to: CGPoint)
    case setParam(NodeID, ParamID, ParamValue)
    case connect(from: SocketRef, to: SocketRef)
    case disconnect(SocketRef)
    case addNode(NodeInstance)
    case removeNode(NodeID)

    public var changeClass: ChangeClass {
        switch self {
        case .moveNode: .cosmetic
        case .setParam(_, _, let v): v.isUniformable ? .parameter : .topology
        case .connect, .disconnect, .addNode, .removeNode: .topology
        }
    }
}
```

- [ ] **Step 5: Write `EditorModel.swift`**

```swift
import Foundation
import Observation
import MetalNodesCore
import MetalNodesRender

@MainActor
@Observable
public final class EditorModel {
    public private(set) var document: ShaderDocument
    public var viewState = EditorViewState()
    public let preview: PreviewState
    public let registry: NodeRegistry
    public private(set) var diagnostics: [Diagnostic] = []
    public private(set) var generatedSource = ""
    public private(set) var resolvedTypes: [NodeID: ResolvedNode] = [:]
    public var debounceInterval: Duration = .milliseconds(150)

    private let compiler: any ShaderCompiling
    private var generation: UInt64 = 0
    private var debounceTask: Task<Void, Never>?
    private var compileTask: Task<Void, Never>?

    public init(document: ShaderDocument, compiler: any ShaderCompiling,
                registry: NodeRegistry = .builtin, preview: PreviewState = PreviewState()) {
        self.document = document
        self.compiler = compiler
        self.registry = registry
        self.preview = preview
    }

    /// First compile, undebounced.
    public func start() {
        compileTask = Task { await self.compileNow() }
    }

    /// Waits for any pending debounce and compile. For tests and for save.
    public func awaitIdle() async {
        await debounceTask?.value
        await compileTask?.value
    }

    public func apply(_ change: DocumentChange) {
        switch change {
        case .moveNode(let id, let p):
            document.root.nodes[id]?.position = p
        case .setParam(let id, let key, let value):
            document.root.nodes[id]?.params[key] = value
        case .connect(let from, let to):
            document.root.connect(from, to: to)
        case .disconnect(let input):
            document.root.disconnect(input)
        case .addNode(let n):
            document.root.nodes[n.id] = n
        case .removeNode(let id):
            document.root.remove(node: id)
        }

        switch change.changeClass {
        case .cosmetic:
            break
        case .parameter:
            if case .setParam(let id, let key, let value) = change, var img = preview.uniforms {
                img.set(value, for: ParamPath(node: id, param: key))
                preview.uniforms = img
            }
        case .topology:
            scheduleCompile()
        }
    }

    private func scheduleCompile() {
        debounceTask?.cancel()
        debounceTask = Task { [debounceInterval] in
            try? await Task.sleep(for: debounceInterval)
            guard !Task.isCancelled else { return }
            self.compileTask = Task { await self.compileNow() }
            await self.compileTask?.value
        }
    }

    private func compileNow() async {
        generation += 1
        let gen = generation
        let doc = document

        let shader: GeneratedShader
        do {
            shader = try ShaderGenerator.generate(doc, target: .fragment, registry: registry)
        } catch GenerationError.invalid(let diags) {
            diagnostics = diags
            return                                   // keep last-good pipeline
        } catch {
            diagnostics = [Diagnostic(.error, "\(error)")]
            return
        }
        diagnostics = []
        generatedSource = shader.source
        resolvedTypes = shader.resolved

        switch await compiler.compile(shader, generation: gen) {
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
                if let node = shader.lineMap.node(forLine: l.line) {
                    mapped.append(Diagnostic(.error, l.message, node: node))
                }
            }
            diagnostics = mapped.isEmpty ? [Diagnostic(.error, message)] : mapped
        case .superseded:
            break
        }
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --package-path MetalNodesKit --filter EditorModelTests 2>&1 | tail -5`
Expected: all EditorModelTests pass. If `compileFailureKeepsLastGoodPipelineAndMapsLines` fails on `diagnostics.contains { $0.node == b.id }`, print `m2.diagnostics` and the failing line numbers — the `LineMap` line arithmetic in `ShaderGenerator` (Task 12, `bodyStart`) is the usual culprit.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): EditorModel with change classification, debounce and last-good pipeline

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 17: Socket, node, wire and canvas views

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/SocketView.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/ParamControl.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/NodeView.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/WireLayer.swift`
- Create: `MetalNodesKit/Sources/MetalNodesUI/Canvas/GraphCanvasView.swift`
- Test: `MetalNodesKit/Tests/MetalNodesUITests/WireGeometryTests.swift`

**Interfaces:**
- Consumes: `EditorModel`, `DocumentChange`, `CanvasTransform`, `DraculaTheme`, `NodeDef`, `ResolvedNode`.
- Produces:
  - `struct SocketAnchorKey: PreferenceKey { typealias Value = [SocketRef: CGPoint] }` — every socket reports its centre in the `"canvas"` coordinate space.
  - `enum WireGeometry { static func path(from: CGPoint, to: CGPoint) -> Path; static func controlOffset(from: CGPoint, to: CGPoint) -> CGFloat }`
  - `struct SocketView: View { init(type: SocketType) }`
  - `struct ParamControl: View { init(label: String, kind: ParamKind, value: ParamValue, onChange: @escaping (ParamValue) -> Void) }`
  - `struct NodeView: View { init(node: NodeInstance, def: NodeDef, resolved: ResolvedNode?, graph: Graph, onChange: @escaping (DocumentChange) -> Void) }`
  - `struct WireLayer: View { init(graph: Graph, anchors: [SocketRef: CGPoint], color: @escaping (SocketRef) -> Color) }`
  - `public struct GraphCanvasView: View { public init(model: EditorModel) }`

Layout approach (spec §11.1): one SwiftUI view per node inside a `ZStack` that carries `.coordinateSpace(.named("canvas"))`; the whole stack is then `.scaleEffect(zoom, anchor: .topLeading).offset(pan)`. Because the named space sits *inside* the transform, socket anchors and drag translations arrive in canvas units with no conversion. Wires are one `Canvas` beneath the nodes. Culling and LOD are M2; the content is a fixed 4000×4000 canvas for M1.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import SwiftUI
@testable import MetalNodesUI
import MetalNodesCore

@Suite struct WireGeometryTests {
    @Test func controlOffsetGrowsWithDistanceButHasAFloor() {
        #expect(WireGeometry.controlOffset(from: .zero, to: CGPoint(x: 10, y: 0)) == 40)
        #expect(WireGeometry.controlOffset(from: .zero, to: CGPoint(x: 400, y: 0)) == 200)
        #expect(WireGeometry.controlOffset(from: CGPoint(x: 400, y: 0), to: .zero) == 200)
    }

    @Test func pathStartsAndEndsAtSockets() {
        let p = WireGeometry.path(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 300, y: 100))
        let box = p.boundingRect
        #expect(box.minX == 0 && box.maxX == 300)
        #expect(box.minY >= 0 && box.maxY <= 100)
    }

    @Test func anchorPreferenceMergesDictionaries() {
        let a = NodeID(), b = NodeID()
        var v: [SocketRef: CGPoint] = [SocketRef(a, "x"): .zero]
        SocketAnchorKey.reduce(value: &v) { [SocketRef(b, "y"): CGPoint(x: 1, y: 1)] }
        #expect(v.count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter WireGeometryTests 2>&1 | tail -3`
Expected: compile error, `cannot find 'WireGeometry' in scope`.

- [ ] **Step 3: Write `SocketView.swift`**

```swift
import SwiftUI
import MetalNodesCore

struct SocketAnchorKey: PreferenceKey {
    static let defaultValue: [SocketRef: CGPoint] = [:]
    static func reduce(value: inout [SocketRef: CGPoint], nextValue: () -> [SocketRef: CGPoint]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Circle for scalars/vectors, diamond for color, square for texture (spec §7.1).
struct SocketView: View {
    let type: SocketType
    static let size: CGFloat = 10

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
    }
}

extension View {
    /// Reports this view's centre, in the "canvas" space, as the anchor for `ref`.
    func socketAnchor(_ ref: SocketRef) -> some View {
        background(GeometryReader { g in
            let f = g.frame(in: .named("canvas"))
            Color.clear.preference(key: SocketAnchorKey.self, value: [ref: CGPoint(x: f.midX, y: f.midY)])
        })
    }
}
```

- [ ] **Step 4: Write `ParamControl.swift`**

```swift
import SwiftUI
import MetalNodesCore

/// The inline editor for one parameter or unwired input.
struct ParamControl: View {
    let label: String
    let kind: ParamKind
    let value: ParamValue
    let onChange: (ParamValue) -> Void

    var body: some View {
        switch kind {
        case .value(let type, let range):
            valueControl(type, range)
        case .enumeration(let cases):
            Picker(label, selection: Binding(
                get: { if case .enumCase(let c) = value { return c } else { return cases.first ?? "" } },
                set: { onChange(.enumCase($0)) })) {
                ForEach(cases, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .pickerStyle(.menu)
            .font(.caption)
        case .asset:
            Text(label).font(.caption).foregroundStyle(DraculaToken.muted.color)
        }
    }

    @ViewBuilder
    private func valueControl(_ type: SocketType, _ range: ClosedRange<Float>?) -> some View {
        switch type {
        case .float:
            let f: Float = { if case .float(let x) = value { return x } else { return 0 } }()
            HStack(spacing: 4) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                Slider(value: Binding(get: { f }, set: { onChange(.float($0)) }), in: range ?? -1...1)
                    .controlSize(.mini)
                Text(f.formatted(.number.precision(.fractionLength(2)))).font(.caption2.monospacedDigit()).frame(width: 36, alignment: .trailing)
            }
        case .int:
            let i: Int32 = { if case .int(let x) = value { return x } else { return 0 } }()
            Stepper("\(label): \(i)", value: Binding(get: { Int(i) }, set: { onChange(.int(Int32($0))) }),
                    in: Int(range?.lowerBound ?? -100)...Int(range?.upperBound ?? 100))
                .font(.caption)
        case .bool:
            let b: Bool = { if case .bool(let x) = value { return x } else { return false } }()
            Toggle(label, isOn: Binding(get: { b }, set: { onChange(.bool($0)) })).font(.caption).toggleStyle(.switch).controlSize(.mini)
        case .color, .float4:
            let v: SIMD4<Float> = { if case .float4(let x) = value { return x } else { return .init(1, 1, 1, 1) } }()
            ColorPicker(label, selection: Binding(
                get: { CGColor(srgbRed: CGFloat(v.x), green: CGFloat(v.y), blue: CGFloat(v.z), alpha: CGFloat(v.w)) },
                set: { c in
                    let comps = (c.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil) ?? c).components ?? [1, 1, 1, 1]
                    onChange(.float4(.init(Float(comps[0]), Float(comps[1]), Float(comps[2]), Float(comps.count > 3 ? comps[3] : 1))))
                }), supportsOpacity: true)
                .font(.caption)
        case .float2, .float3:
            let comps: [Float] = {
                switch value {
                case .float2(let x): [x.x, x.y]
                case .float3(let x): [x.x, x.y, x.z]
                case .float(let x): [x, x, x]
                default: [0, 0, 0]
                }
            }()
            let n = type.componentCount ?? 3
            HStack(spacing: 2) {
                Text(label).font(.caption).frame(width: 46, alignment: .leading)
                ForEach(0..<n, id: \.self) { i in
                    TextField("", value: Binding(
                        get: { i < comps.count ? comps[i] : 0 },
                        set: { x in
                            var c = Array(comps.prefix(n)) + Array(repeating: Float(0), count: max(0, n - comps.count))
                            c[i] = x
                            onChange(n == 2 ? .float2(.init(c[0], c[1])) : .float3(.init(c[0], c[1], c[2])))
                        }), format: .number.precision(.fractionLength(2)))
                        .textFieldStyle(.roundedBorder).font(.caption2).frame(width: 44)
                }
            }
        case .texture:
            EmptyView()
        }
    }
}
```

- [ ] **Step 5: Write `NodeView.swift`**

```swift
import SwiftUI
import MetalNodesCore

struct NodeView: View {
    let node: NodeInstance
    let def: NodeDef
    let resolved: ResolvedNode?
    let graph: Graph
    let onChange: (DocumentChange) -> Void

    @State private var dragOrigin: CGPoint?
    static let width: CGFloat = 190

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            VStack(alignment: .leading, spacing: 6) {
                ForEach(def.inputs, id: \.name) { inputRow($0) }
                ForEach(def.params, id: \.name) { param in
                    ParamControl(label: param.label, kind: param.kind,
                                 value: node.params[param.name] ?? param.defaultValue) {
                        onChange(.setParam(node.id, param.name, $0))
                    }
                }
                ForEach(def.outputs, id: \.name) { outputRow($0) }
            }
            .padding(8)
        }
        .frame(width: Self.width)
        .background(DraculaToken.surface.color)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DraculaToken.background.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
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
            DragGesture(coordinateSpace: .named("canvas"))
                .onChanged { g in
                    if dragOrigin == nil { dragOrigin = node.position }
                    let o = dragOrigin!
                    onChange(.moveNode(node.id, to: CGPoint(x: o.x + g.translation.width, y: o.y + g.translation.height)))
                }
                .onEnded { _ in dragOrigin = nil }
        )
    }

    private func inputRow(_ decl: SocketDecl) -> some View {
        let ref = SocketRef(node.id, decl.name)
        let type = resolved?.inputTypes[decl.name] ?? concrete(decl.type)
        let wired = graph.inputs[ref] != nil
        return HStack(spacing: 6) {
            SocketView(type: type).socketAnchor(ref).offset(x: -8 - SocketView.size / 2)
            if !wired, case .value(let dflt) = decl.default {
                ParamControl(label: decl.label, kind: .value(type, range: nil), value: coerced(node.params[decl.name] ?? dflt, to: type)) {
                    onChange(.setParam(node.id, decl.name, $0))
                }
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

    /// Show a stored scalar as the resolved vector type so the control matches the socket.
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

- [ ] **Step 6: Write `WireLayer.swift`**

```swift
import SwiftUI
import MetalNodesCore

enum WireGeometry {
    /// Horizontal handle length: half the horizontal distance, never less than 40 (spec §11.1).
    static func controlOffset(from a: CGPoint, to b: CGPoint) -> CGFloat {
        max(40, abs(b.x - a.x) * 0.5)
    }

    static func path(from a: CGPoint, to b: CGPoint) -> Path {
        let d = controlOffset(from: a, to: b)
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + d, y: a.y), control2: CGPoint(x: b.x - d, y: b.y))
        return p
    }
}

/// All wires in one `Canvas`, drawn beneath the nodes.
struct WireLayer: View {
    let graph: Graph
    let anchors: [SocketRef: CGPoint]
    let color: (SocketRef) -> Color

    var body: some View {
        Canvas { ctx, _ in
            for (to, from) in graph.inputs {
                guard let a = anchors[from], let b = anchors[to] else { continue }
                ctx.stroke(WireGeometry.path(from: a, to: b), with: .color(color(from)), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
    }
}
```

- [ ] **Step 7: Write `GraphCanvasView.swift`**

```swift
import SwiftUI
import MetalNodesCore

public struct GraphCanvasView: View {
    let model: EditorModel
    @State private var transform = CanvasTransform()
    @State private var anchors: [SocketRef: CGPoint] = [:]
    @State private var panOrigin: CGSize?
    @State private var zoomOrigin: CGFloat?

    static let contentSize: CGFloat = 4000

    public init(model: EditorModel) { self.model = model }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            DraculaToken.background.color
            gridDots
            content
                .frame(width: Self.contentSize, height: Self.contentSize, alignment: .topLeading)
                .scaleEffect(transform.zoom, anchor: .topLeading)
                .offset(transform.pan)
        }
        .clipped()
        .contentShape(Rectangle())
        .gesture(panGesture)
        .simultaneousGesture(magnifyGesture)
        .onPreferenceChange(SocketAnchorKey.self) { anchors = $0 }
        .onAppear { if let cam = model.viewState.cameras[.root] { transform = CanvasTransform(camera: cam) } }
    }

    private var content: some View {
        ZStack(alignment: .topLeading) {
            WireLayer(graph: model.document.root, anchors: anchors) { from in
                if let t = model.resolvedTypes[from.node]?.outputTypes[from.socket] {
                    return DraculaTheme.token(for: t).color
                }
                return DraculaTheme.wireDefault.color
            }
            ForEach(Array(model.document.root.nodes.values), id: \.id) { node in
                if case .builtin(let defID) = node.kind, let def = model.registry[defID] {
                    NodeView(node: node, def: def, resolved: model.resolvedTypes[node.id],
                             graph: model.document.root) { model.apply($0) }
                        .offset(x: node.position.x, y: node.position.y)
                }
            }
        }
        .coordinateSpace(.named("canvas"))
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

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { g in
                if panOrigin == nil { panOrigin = transform.pan }
                transform.pan = CGSize(width: panOrigin!.width + g.translation.width, height: panOrigin!.height + g.translation.height)
            }
            .onEnded { _ in panOrigin = nil; model.viewState.cameras[.root] = transform.camera }
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

- [ ] **Step 8: Run tests and build**

Run: `swift test --package-path MetalNodesKit --filter WireGeometryTests 2>&1 | tail -3`
Expected: all WireGeometryTests pass.

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -E 'error|Build complete' | tail -5`
Expected: `Build complete!`, no errors.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): node, socket, wire and pan/zoom canvas views

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 18: EditorView, app wiring, and first pixels

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift` (add `resetRequested`)
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift` (consume `resetRequested`)
- Modify: `MetalNodes/MetalNodesApp.swift`
- Delete: `MetalNodes/ContentView.swift`

**Interfaces:**
- Consumes: `EditorModel`, `GraphCanvasView`, `PreviewView`, `PreviewState`, `ShaderCompiler`.
- Produces: `public struct EditorView: View { public init(model: EditorModel, device: MTLDevice) }`; `PreviewState.resetRequested: Bool`.

- [ ] **Step 1: Add the time-reset hand-off to the renderer**

In `PreviewState.swift`, add after `public var timeOffset: Float = 0`:

```swift
    /// Set by the UI; the renderer zeroes the clock on the next frame and clears it.
    public var resetRequested = false
```

In `ShaderRenderer.swift`, replace the line `let now = Float(CACurrentMediaTime() - startTime)` with:

```swift
        let now = Float(CACurrentMediaTime() - startTime)
        if state.resetRequested { state.timeOffset = now; pausedAt = nil; state.resetRequested = false }
```

- [ ] **Step 2: Write `EditorView.swift`**

```swift
import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender

public struct EditorView: View {
    let model: EditorModel
    let device: MTLDevice

    public init(model: EditorModel, device: MTLDevice) {
        self.model = model
        self.device = device
    }

    public var body: some View {
        split
            .background(DraculaToken.background.color)
            .preferredColorScheme(.dark)
            .tint(DraculaToken.purple.color)
    }

    @ViewBuilder
    private var split: some View {
        #if os(macOS)
        HSplitView {
            GraphCanvasView(model: model).frame(minWidth: 480)
            previewPane.frame(minWidth: 320, idealWidth: 420)
        }
        #else
        HStack(spacing: 0) {
            GraphCanvasView(model: model)
            previewPane.frame(width: 420)
        }
        #endif
    }

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
            Spacer()
        }
        .padding(10)
    }

    private var diagnosticsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let err = model.preview.lastError {
                Text(err).font(.caption2.monospaced()).foregroundStyle(DraculaTheme.error.color).lineLimit(6)
            }
            ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, d in
                Text(d.message).font(.caption).foregroundStyle(d.severity == .error ? DraculaTheme.error.color : DraculaToken.orange.color)
            }
            if model.diagnostics.isEmpty && model.preview.lastError == nil {
                Text("No problems").font(.caption).foregroundStyle(DraculaToken.muted.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
```

- [ ] **Step 3: Wire the app**

Delete `MetalNodes/ContentView.swift`. Replace `MetalNodes/MetalNodesApp.swift`:

```swift
import SwiftUI
import Metal
import MetalNodesCore
import MetalNodesRender
import MetalNodesUI

@main
struct MetalNodesApp: App {
    private let device: MTLDevice
    @State private var model: EditorModel

    init() {
        guard let device = MTLCreateSystemDefaultDevice() else { fatalError("Metal is required") }
        self.device = device
        let compiler: ShaderCompiler
        do { compiler = try ShaderCompiler(device: device) }
        catch { fatalError("Could not build the vertex stage: \(error)") }
        _model = State(initialValue: EditorModel(document: .sample(), compiler: compiler))
    }

    var body: some Scene {
        WindowGroup("MetalNodes") {
            EditorView(model: model, device: device)
                .frame(minWidth: 960, minHeight: 620)
                .onAppear { model.start() }
        }
    }
}
```

- [ ] **Step 4: Build the app**

Run: `xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | grep -E 'error:|BUILD' | head`
Expected: `** BUILD SUCCEEDED **`, no `error:` lines.

- [ ] **Step 5: Run the full test suite**

Run: `swift test --package-path MetalNodesKit 2>&1 | tail -3`
Expected: all tests pass, zero failures.

- [ ] **Step 6: Launch and verify first pixels by hand**

```bash
APP=$(xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/ {print $3}')/MetalNodes.app
open "$APP"
```

Check each of these, and stop to fix before committing if any fails:

1. The window opens with a dark `#282A36` canvas, eleven nodes with colored headers, and wires colored by type (cyan for `float`, green for `float2`, purple for `float3`, yellow for `color`).
2. The preview shows a red/green gradient (uv) whose blue channel pulses over time, mottled by noise mixed with the purple tint.
3. "No problems" is shown; the gen counter reads `1`.
4. Drag the **Float** node's `Value` slider: the pulse speed changes immediately and the gen counter **stays at 1** — no recompile (spec §10).
5. Change the **Math** node's operation from `sine` to `fract`: the picture changes and the gen counter becomes `2`.
6. Drag a node by its header: it moves, its wires follow, gen stays put.
7. Pinch (trackpad) to zoom; drag empty canvas to pan.
8. Pause freezes the animation; Reset restarts the clock.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit MetalNodes
git commit -m "feat: editor window with live Metal preview — first pixels

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

## Done criteria for this plan

- `swift test --package-path MetalNodesKit` is green.
- The macOS app builds and the eight manual checks in Task 18 pass.
- No file outside `DraculaTheme.swift` contains a color hex literal (`grep -rn '0x[0-9A-Fa-f]\{6\}' MetalNodesKit/Sources --include=*.swift | grep -v DraculaTheme` prints nothing).
- `MetalNodesCore` imports nothing but Foundation/CoreGraphics (`grep -rn '^import' MetalNodesKit/Sources/MetalNodesCore | grep -vE 'Foundation|CoreGraphics'` prints nothing).

## What the next plan (M2) starts from

`EditorModel.apply(_:)` already accepts `connect`, `disconnect`, `addNode`, `removeNode` — M2 adds the palette, socket-drag wiring, selection, marquee, copy/paste and undo on top of that API without changing it. `EditorViewState` already has `selection`, `viewer` and `editingStack` fields waiting for M2–M4.
