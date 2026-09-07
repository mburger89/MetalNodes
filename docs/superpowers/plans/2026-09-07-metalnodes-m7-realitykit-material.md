# MetalNodes M7 — RealityKit Material Target Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third output target — a RealityKit `CustomMaterial` emitted as a surface shader plus a geometry modifier from one graph — with a 3D lit preview on a procedural mesh and a `.metal` + `.swift` export.

**Architecture:** One new terminal node (`output.material`) carries both shader stages. `ShaderGenerator` runs the existing emitter twice over the same document, once per stage, through two new `EmitEnvironment`s; the exported `.metal` holds two `[[visible]]` functions with every parameter baked as a literal, and the preview holds a *separately generated* vertex+fragment program that runs the same statements on a mesh under a GGX approximation of RealityKit's `.lit` model. The existing fullscreen-triangle path, the fragment target and the three stitchable targets are not modified.

**Tech Stack:** Swift 6.4 (strict concurrency), SwiftUI, Metal / MetalKit, Swift Testing, SwiftPM package `MetalNodesKit` (targets `MetalNodesCore`, `MetalNodesRender`, `MetalNodesUI`) plus the app target `MetalNodes`.

**Spec:** `docs/superpowers/specs/2026-09-04-metalnodes-design.md` — §23 is this milestone. §9 (codegen), §10 (render/compile loop), §19 (targets and export), §20 (groups), §21 (textures) are the machinery it extends.

## Global Constraints

- **Swift 6.4, strict concurrency, warning-free.** `swift build --package-path MetalNodesKit` must emit no warnings. Public API in `MetalNodesCore` is `Sendable` value types; `MetalNodesCore` imports no AppKit/UIKit/Metal.
- **Never commit `MetalNodes.xcodeproj/project.pbxproj`** unless the task explicitly adds a file to the app target. Xcode rewrites it on open/build; run `git checkout -- MetalNodes.xcodeproj/project.pbxproj` after any `xcodebuild`.
- **Xcode Cloud builds with Xcode 26.6**, not the local Xcode 27 beta. Reproduce a cloud failure with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild …`.
- **The existing 2D paths must not change behaviour.** No golden source for `.fragment` or any `.stitchable` target may change. If a test in `ShaderGeneratorTests`, `StitchableCodegenTests`, `LayerVariantTests`, `TextureCodegenTests` or `FragmentExportTests` changes output, the change is a defect, not a rebaseline.
- **`CustomMaterial` is `@available(visionOS, unavailable)`.** Nothing in this milestone changes the app's deployment targets; no RealityKit framework is imported by the app or the package. The RealityKit surface is *generated text only*.
- **The preview program never includes a RealityKit header.** Those headers ship with Xcode, not with the OS, and `MTLCompileOptions` has no include-path knob (verified by probe, 2026-09-06).
- **Every surface setter takes `half`/`half3` except `set_normal`, which takes a tangent-space `float3`.** Verbatim from `RealityKitSurfaceShader.h`.
- **One texture slot, in the root graph only.** `params.textures().custom()` is a `texture2d<half>`; a group function's texture parameters are `texture2d<float>` and MSL converts neither (spec §23.6). A second sample, or one inside a group, is a diagnostic.
- **`mn_sampler` is a program-scope `constexpr sampler` from the stdlib** (`MSLStdlib`, pulled in by the Texture Sample node's `requires`). Never declare another inside a generated function.
- Commit trailers on every commit:
  ```
  Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF
  ```
- Test command for the package: `swift test --package-path MetalNodesKit`. A single suite: `swift test --package-path MetalNodesKit --filter <SuiteName>`.

---

## File Structure

**Created — `MetalNodesCore`:**

| File | Responsibility |
|---|---|
| `Sources/MetalNodesCore/MaterialStage.swift` | `MaterialStage`, `MaterialLightingModel` — two small enums, no dependencies |
| `Sources/MetalNodesCore/ParamValues.swift` | `ParamValues.value(for:in:registry:)` — the document lookup that answers "what value does this uniform slot hold right now"; shared by `UniformImage.rebuild` and by literal baking |
| `Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift` | `output.material` and the ten 3D input nodes |
| `Sources/MetalNodesCore/Codegen/MaterialCodegen.swift` | The RealityKit export: setter table, stage partition, literal baking, the two `[[visible]]` functions |
| `Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift` | The 3D preview program: generated vertex stage, interpolants, GGX shading |
| `Sources/MetalNodesCore/Codegen/MaterialValidation.swift` | Validation rules 2–5 (stage legality, target legality, texture count, lighting model) |
| `Sources/MetalNodesCore/Export/MaterialExport.swift` | The exported `.metal` header comment and the `.swift` snippet |

**Created — `MetalNodesRender`:**

| File | Responsibility |
|---|---|
| `Sources/MetalNodesRender/MeshVertex.swift` | `MeshVertex`, `PreviewMesh` |
| `Sources/MetalNodesRender/MeshBuilder.swift` | Pure CPU generation of the four meshes |
| `Sources/MetalNodesRender/CameraUniforms.swift` | `OrbitCamera` and the matrices it produces |
| `Sources/MetalNodesRender/MeshResources.swift` | `MTLBuffer` cache keyed by `PreviewMesh` |

**Created — tests:**

`Tests/MetalNodesCoreTests/`: `MaterialStageTests.swift`, `Material3DLibraryTests.swift`, `ParamValuesTests.swift`, `MaterialCodegenTests.swift`, `MaterialPreviewCodegenTests.swift`, `MaterialValidationTests.swift`, `MaterialExportTests.swift`.
`Tests/MetalNodesRenderTests/`: `MeshBuilderTests.swift`, `CameraUniformsTests.swift`, `MaterialCompileTests.swift`.

**Modified:**

| File | Change |
|---|---|
| `Sources/MetalNodesCore/Codegen/Diagnostic.swift` | `OutputTarget.realityKit` |
| `Sources/MetalNodesCore/NodeDef.swift` | `NodeDef.stages` |
| `Sources/MetalNodesCore/ShaderDocument.swift` | `DocumentSettings.lightingModel`; `target` decodes with `try?` |
| `Sources/MetalNodesCore/EditorViewState.swift` | `previewMesh`, `orbit` |
| `Sources/MetalNodesCore/Library/BuiltinNodes.swift` | `all` gains `material3D` |
| `Sources/MetalNodesCore/Codegen/EmitEnvironment.swift` | `realityKitSurface`, `realityKitGeometry` |
| `Sources/MetalNodesCore/Codegen/ShaderGenerator.swift` | target-aware terminal, `.realityKit` branch, two new `GeneratedShader` fields |
| `Sources/MetalNodesCore/Codegen/Validation.swift` | `terminal(in:target:)`, target-conditional terminal rules, `.realityKit` branch calls `MaterialValidation` |
| `Sources/MetalNodesCore/Export/ShaderExport.swift` | `.realityKit` branch |
| `Sources/MetalNodesRender/UniformImage.swift` | `rebuild` delegates to `ParamValues` |
| `Sources/MetalNodesRender/ShaderCompiler.swift` | `vertexFunctionName`, depth attachment, cache key |
| `Sources/MetalNodesRender/ShaderRenderer.swift` | 3D draw path |
| `Sources/MetalNodesRender/PreviewState.swift` | `mesh`, `orbit`, `camera` |
| `Sources/MetalNodesUI/Editor/InspectorView.swift` | Lighting Model and Preview Mesh pickers; export button gating |
| `Sources/MetalNodesUI/Editor/EditorView.swift` | preview drag orbits under `.realityKit` |
| `Sources/MetalNodesUI/Editor/EditorModel.swift` | publishes mesh/orbit into `PreviewState` |
| `README.md`, `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` | §14 M7 record |

---

### Task 1: Stage and lighting types, the new target, document settings

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/MaterialStage.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift:24-42`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift:88-107`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift:34-80`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialStageTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/DocumentSettingsTests.swift` (append)

**Interfaces:**
- Produces: `MaterialStage.surface` / `.geometry`, `MaterialStage.all: Set<MaterialStage>`; `MaterialLightingModel.lit` / `.unlit`; `OutputTarget.realityKit`; `NodeDef.stages: Set<MaterialStage>` (defaults to `.all`); `DocumentSettings.lightingModel: MaterialLightingModel`.
- Consumes: nothing.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialStageTests.swift`:

```swift
import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct MaterialStageTests {
    @Test func allIsBothStages() {
        #expect(MaterialStage.all == [.surface, .geometry])
        #expect(Set(MaterialStage.allCases) == MaterialStage.all)
    }

    @Test func stagesRoundTripThroughCoding() throws {
        let data = try JSONEncoder().encode([MaterialStage.geometry])
        #expect(try JSONDecoder().decode([MaterialStage].self, from: data) == [.geometry])
    }

    @Test func realityKitIsAnOutputTargetWithATitle() {
        #expect(OutputTarget.all.contains(.realityKit))
        #expect(OutputTarget.realityKit.title == "RealityKit Material")
        #expect(OutputTarget.realityKit.stitchableKind == nil)
    }

    @Test func everyBuiltinNodeIsLegalInBothStagesByDefault() {
        // Task 2 narrows a handful; before it lands, the default must be "both".
        for def in NodeRegistry.builtin.all where !def.id.hasPrefix("input.") {
            #expect(def.stages == MaterialStage.all, "\(def.id)")
        }
    }
}
```

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/DocumentSettingsTests.swift`:

```swift
@Suite struct MaterialDocumentSettingsTests {
    @Test func lightingModelDefaultsToLitAndRoundTrips() throws {
        var s = DocumentSettings()
        #expect(s.lightingModel == .lit)
        s.lightingModel = .unlit
        s.target = .realityKit
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: data)
        #expect(back.lightingModel == .unlit)
        #expect(back.target == .realityKit)
    }

    @Test func settingsWithoutALightingModelDecodeAsLit() throws {
        let json = Data(#"{"fastMath":true,"exportName":"x"}"#.utf8)
        #expect(try JSONDecoder().decode(DocumentSettings.self, from: json).lightingModel == .lit)
    }

    /// A document written by a newer build must open, not fail: an unrecognised target
    /// falls back to Fragment rather than throwing out the whole settings object.
    @Test func anUnknownTargetFallsBackToFragment() throws {
        let json = Data(#"{"target":{"holographic":{}},"exportName":"x"}"#.utf8)
        let back = try JSONDecoder().decode(DocumentSettings.self, from: json)
        #expect(back.target == .fragment)
        #expect(back.exportName == "x")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter MaterialStageTests`
Expected: FAIL — `MaterialStage` is not defined, `OutputTarget` has no `realityKit`.

- [ ] **Step 3: Create the stage and lighting types**

Create `MetalNodesKit/Sources/MetalNodesCore/MaterialStage.swift`:

```swift
import Foundation

/// The two shader stages a RealityKit `CustomMaterial` is authored from (spec §23.2). One graph
/// emits both: the surface shader runs per fragment, the geometry modifier per vertex.
public enum MaterialStage: String, Codable, Sendable, CaseIterable, Hashable {
    case surface, geometry

    public static let all: Set<MaterialStage> = [.surface, .geometry]

    /// How the stage names itself in a diagnostic.
    public var title: String {
        switch self {
        case .surface: "surface"
        case .geometry: "geometry"
        }
    }
}

/// `CustomMaterial.LightingModel`, minus `.clearcoat` — that model only unlocks setters no socket
/// produces, so offering it would change nothing (spec §23.2).
public enum MaterialLightingModel: String, Codable, Sendable, CaseIterable, Hashable {
    case lit, unlit

    public var title: String {
        switch self {
        case .lit: "Lit (PBR)"
        case .unlit: "Unlit"
        }
    }

    /// The `CustomMaterial.LightingModel` case the exported Swift snippet names.
    public var swiftCase: String { ".\(rawValue)" }
}
```

- [ ] **Step 4: Add the target case**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift`, extend `OutputTarget`:

```swift
public enum OutputTarget: Sendable, Hashable, Codable {
    case fragment
    case stitchable(StitchableKind)
    case realityKit

    public static let all: [OutputTarget] = [.fragment, .stitchable(.colorEffect), .stitchable(.distortionEffect), .stitchable(.layerEffect), .realityKit]

    public var title: String {
        switch self {
        case .fragment: "Fragment (preview)"
        case .stitchable(.colorEffect): "SwiftUI Color Effect"
        case .stitchable(.distortionEffect): "SwiftUI Distortion Effect"
        case .stitchable(.layerEffect): "SwiftUI Layer Effect"
        case .realityKit: "RealityKit Material"
        }
    }

    public var stitchableKind: StitchableKind? {
        if case .stitchable(let k) = self { return k } else { return nil }
    }
}
```

- [ ] **Step 4: Add `NodeDef.stages`**

In `MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift`, add the property and initializer parameter. Place `stages` after `requires` in both the property list and the initializer, and give it a default so no existing `NodeDef(...)` call site changes:

```swift
    public var requires: [String]
    /// Which RealityKit shader stages this node may appear in (spec §23.3). Both for every node
    /// that is pure arithmetic; narrowed only by nodes that read a stage-specific builtin.
    /// Consulted only under `OutputTarget.realityKit`.
    public var stages: Set<MaterialStage> = MaterialStage.all
    public var body: NodeBody
    public var style: NodeStyle

    public init(id: String, title: String, category: NodeCategory,
                inputs: [SocketDecl] = [], outputs: [SocketDecl] = [], params: [ParamDecl] = [],
                generics: [String: [SocketType]] = [:], requires: [String] = [],
                stages: Set<MaterialStage> = MaterialStage.all, body: NodeBody,
                style: NodeStyle = .standard) {
        self.id = id; self.title = title; self.category = category
        self.inputs = inputs; self.outputs = outputs; self.params = params
        self.generics = generics; self.requires = requires; self.stages = stages
        self.body = body; self.style = style
    }
```

- [ ] **Step 5: Add the lighting model to document settings**

In `MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift`, add the property to `DocumentSettings`:

```swift
    /// The `CustomMaterial.LightingModel` the RealityKit target exports and the 3D preview
    /// approximates (spec §23.8). Ignored by every other target.
    public var lightingModel: MaterialLightingModel = .lit
```

In the `Codable` extension, add `lightingModel` to `Keys`, decode it, and — critically — make `target` tolerant:

```swift
    private enum Keys: String, CodingKey { case previewSize, timeMode, fastMath, target, exportName, assets, lightingModel }
```

```swift
        // A document written by a newer build may name a target this build has no case for.
        // `decodeIfPresent` *throws* on an unknown case, which would fail the whole settings
        // object and so the whole document; `try?` degrades to Fragment instead (spec §23.2).
        target = (try? c.decodeIfPresent(OutputTarget.self, forKey: .target)) .flatMap { $0 } ?? .fragment
        lightingModel = (try? c.decodeIfPresent(MaterialLightingModel.self, forKey: .lightingModel)).flatMap { $0 } ?? .lit
```

Add `lightingModel` to `encode(to:)` beside `target`.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --package-path MetalNodesKit --filter MaterialStageTests`
Run: `swift test --package-path MetalNodesKit --filter DocumentSettings`
Expected: PASS.

- [ ] **Step 7: Run the whole suite — no existing test may change**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS, same count as before plus the new tests. If `BuiltinLibraryTests.registryContainsTheV1Set` fails, you added nodes in this task — you should not have; that is Task 2.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/MaterialStage.swift \
        MetalNodesKit/Sources/MetalNodesCore/Codegen/Diagnostic.swift \
        MetalNodesKit/Sources/MetalNodesCore/NodeDef.swift \
        MetalNodesKit/Sources/MetalNodesCore/ShaderDocument.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/MaterialStageTests.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/DocumentSettingsTests.swift
git commit -m "feat(core): material stages, lighting model and the RealityKit target case

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 2: The Material Output node and the ten 3D input nodes

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift:15-21`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/Material3DLibraryTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/BuiltinLibraryTests.swift:5-25` (extend the expected id set)

**Interfaces:**
- Consumes: `MaterialStage`, `NodeDef.stages` (Task 1).
- Produces: node ids `output.material`, `input.worldPosition`, `input.modelPosition`, `input.normal3d`, `input.tangent`, `input.bitangent`, `input.viewDirection`, `input.uv1`, `input.vertexColor`, `input.vertexID`, `input.screenPosition`; `BuiltinNodes.materialStages: [String: MaterialStage]` mapping a Material Output socket name to its stage; `BuiltinNodes.material3D: [NodeDef]`.

The node bodies use `{sys.<name>}` placeholders so one definition serves both stages — the *environment* (Task 5) decides whether `{sys.normal3d}` spells `params.geometry().normal()` or `g.normal()`. This is exactly how `input.uv` already works.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/Material3DLibraryTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct Material3DLibraryTests {
    private func def(_ id: String) -> NodeDef {
        guard let d = NodeRegistry.builtin[id] else { Issue.record("missing node \(id)"); return NodeDef(id: id, title: id, category: .input, body: .template("")) }
        return d
    }

    @Test func theMaterialOutputHasNineSocketsInSpecOrder() {
        let d = def("output.material")
        #expect(d.category == .output)
        #expect(d.inputs.map(\.name) == ["baseColor", "normal", "roughness", "metallic",
                                         "emissive", "opacity", "occlusion", "specular", "positionOffset"])
        #expect(d.outputs.isEmpty)
    }

    @Test func materialOutputSocketTypesMatchTheSetterTable() {
        let types = Dictionary(uniqueKeysWithValues: def("output.material").inputs.map { ($0.name, $0.type) })
        #expect(types["baseColor"] == .concrete(.color))
        #expect(types["normal"] == .concrete(.float3))
        #expect(types["roughness"] == .concrete(.float))
        #expect(types["metallic"] == .concrete(.float))
        #expect(types["emissive"] == .concrete(.color))
        #expect(types["opacity"] == .concrete(.float))
        #expect(types["occlusion"] == .concrete(.float))
        #expect(types["specular"] == .concrete(.float))
        #expect(types["positionOffset"] == .concrete(.float3))
    }

    @Test func eightSocketsAreSurfaceAndOneIsGeometry() {
        let surface = BuiltinNodes.materialStages.filter { $0.value == .surface }.keys.sorted()
        #expect(surface == ["baseColor", "emissive", "metallic", "normal", "occlusion", "opacity", "roughness", "specular"])
        #expect(BuiltinNodes.materialStages["positionOffset"] == .geometry)
        // Every socket of the terminal has a stage; none is unclassified.
        #expect(Set(def("output.material").inputs.map(\.name)) == Set(BuiltinNodes.materialStages.keys))
    }

    @Test func stageOnlyNodesDeclareTheirStage() {
        #expect(def("input.tangent").stages == [.surface])
        #expect(def("input.viewDirection").stages == [.surface])
        #expect(def("input.screenPosition").stages == [.surface])
        #expect(def("input.vertexID").stages == [.geometry])
        for id in ["input.worldPosition", "input.modelPosition", "input.normal3d",
                   "input.bitangent", "input.uv1", "input.vertexColor"] {
            #expect(def(id).stages == MaterialStage.all, id)
        }
    }

    @Test func theThreeDimensionalInputsOutputTheDeclaredTypes() {
        let expected: [String: SocketType] = [
            "input.worldPosition": .float3, "input.modelPosition": .float3, "input.normal3d": .float3,
            "input.tangent": .float3, "input.bitangent": .float3, "input.viewDirection": .float3,
            "input.uv1": .float2, "input.vertexColor": .color, "input.vertexID": .int,
            "input.screenPosition": .float4,
        ]
        for (id, type) in expected {
            let d = def(id)
            #expect(d.outputs.count == 1, id)
            #expect(d.outputs.first?.type == .concrete(type), id)
            #expect(d.category == .input, id)
        }
    }

    /// Every `{sys.x}` a 3D node names must be a key both RealityKit environments provide,
    /// otherwise the emitter substitutes a comment marker into real source.
    @Test func everySysPlaceholderIsAKnownSystemName() {
        let known: Set<String> = ["uv", "time", "resolution", "mouse", "uv1", "worldPosition",
                                  "modelPosition", "normal3d", "tangent", "bitangent",
                                  "viewDirection", "vertexColor", "vertexID", "screenPosition"]
        for d in BuiltinNodes.material3D {
            guard case .template(let t) = d.body else { continue }
            for m in t.matches(of: NodeRegistry.placeholderPattern) where m.1 == "sys" {
                #expect(known.contains(String(m.2)), "\(d.id) names {sys.\(m.2)}")
            }
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter Material3DLibraryTests`
Expected: FAIL — `BuiltinNodes.material3D` is not defined; every `def(...)` records "missing node".

- [ ] **Step 3: Write the node definitions**

Create `MetalNodesKit/Sources/MetalNodesCore/Library/Builtin/Material3DNodes.swift`:

```swift
import Foundation

extension BuiltinNodes {
    /// Which stage each Material Output socket belongs to (spec §23.2). Eight surface sockets and
    /// one geometry socket; the generator partitions the graph by this map.
    public static let materialStages: [String: MaterialStage] = [
        "baseColor": .surface, "normal": .surface, "roughness": .surface, "metallic": .surface,
        "emissive": .surface, "opacity": .surface, "occlusion": .surface, "specular": .surface,
        "positionOffset": .geometry,
    ]

    /// The RealityKit terminal and the per-vertex/per-fragment builtins only that target can read
    /// (spec §23.2, §23.3). Every body spells its value as `{sys.…}`, so one definition serves both
    /// stages and the `EmitEnvironment` decides the accessor.
    public static let material3D: [NodeDef] = [
        NodeDef(id: "output.material", title: "Material Output", category: .output,
                inputs: [
                    SocketDecl(name: "baseColor", label: "Base Color", type: .concrete(.color),
                               default: .value(.float4(.init(0.8, 0.8, 0.8, 1)))),
                    SocketDecl(name: "normal", label: "Normal", type: .concrete(.float3),
                               default: .value(.float3(.init(0, 0, 1)))),
                    SocketDecl(name: "roughness", label: "Roughness", type: .concrete(.float),
                               default: .value(.float(0.5))),
                    SocketDecl(name: "metallic", label: "Metallic", type: .concrete(.float),
                               default: .value(.float(0))),
                    SocketDecl(name: "emissive", label: "Emissive", type: .concrete(.color),
                               default: .value(.float4(.init(0, 0, 0, 1)))),
                    SocketDecl(name: "opacity", label: "Opacity", type: .concrete(.float),
                               default: .value(.float(1))),
                    SocketDecl(name: "occlusion", label: "Ambient Occlusion", type: .concrete(.float),
                               default: .value(.float(1))),
                    SocketDecl(name: "specular", label: "Specular", type: .concrete(.float),
                               default: .value(.float(0.5))),
                    SocketDecl(name: "positionOffset", label: "Position Offset", type: .concrete(.float3),
                               default: .value(.float3(.init(0, 0, 0)))),
                ],
                // Never emitted: `MaterialCodegen` writes each stage's setter block itself,
                // because one body cannot serve two stages with different setters (spec §23.2).
                body: .template("")),

        NodeDef(id: "input.worldPosition", title: "World Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float3))],
                body: .template("{out.position} = {sys.worldPosition};")),
        NodeDef(id: "input.modelPosition", title: "Model Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float3))],
                body: .template("{out.position} = {sys.modelPosition};")),
        NodeDef(id: "input.normal3d", title: "Normal", category: .input,
                outputs: [SocketDecl(name: "normal", type: .concrete(.float3))],
                body: .template("{out.normal} = {sys.normal3d};")),
        NodeDef(id: "input.tangent", title: "Tangent", category: .input,
                outputs: [SocketDecl(name: "tangent", type: .concrete(.float3))],
                stages: [.surface],
                body: .template("{out.tangent} = {sys.tangent};")),
        NodeDef(id: "input.bitangent", title: "Bitangent", category: .input,
                outputs: [SocketDecl(name: "bitangent", type: .concrete(.float3))],
                body: .template("{out.bitangent} = {sys.bitangent};")),
        NodeDef(id: "input.viewDirection", title: "View Direction", category: .input,
                outputs: [SocketDecl(name: "direction", type: .concrete(.float3))],
                stages: [.surface],
                body: .template("{out.direction} = {sys.viewDirection};")),
        NodeDef(id: "input.uv1", title: "UV1", category: .input,
                outputs: [SocketDecl(name: "uv", type: .concrete(.float2))],
                body: .template("{out.uv} = {sys.uv1};")),
        NodeDef(id: "input.vertexColor", title: "Vertex Color", category: .input,
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                body: .template("{out.color} = {sys.vertexColor};")),
        NodeDef(id: "input.vertexID", title: "Vertex ID", category: .input,
                outputs: [SocketDecl(name: "id", type: .concrete(.int))],
                stages: [.geometry],
                body: .template("{out.id} = {sys.vertexID};")),
        NodeDef(id: "input.screenPosition", title: "Screen Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float4))],
                stages: [.surface],
                body: .template("{out.position} = {sys.screenPosition};")),
    ]
}
```

`SocketDecl.init(name:label:type:default:range:)` defaults `label` to `name.capitalized`, so the explicit labels above exist only where that default reads badly ("Base Color", not "Basecolor"). The socket *names* are load-bearing — Task 5's setter table keys on them.

- [ ] **Step 4: Register the nodes**

In `MetalNodesKit/Sources/MetalNodesCore/Library/BuiltinNodes.swift`, add `material3D` to `all`:

```swift
    public static let all: [NodeDef] = input + math + vector + sdf + noise + color + utility + texture + output + material3D
```

- [ ] **Step 5: Extend the library census test**

In `MetalNodesKit/Tests/MetalNodesCoreTests/BuiltinLibraryTests.swift`, add the eleven new ids to the `expected` set in `registryContainsTheV1Set`:

```swift
            "output.material",
            "input.worldPosition", "input.modelPosition", "input.normal3d", "input.tangent",
            "input.bitangent", "input.viewDirection", "input.uv1", "input.vertexColor",
            "input.vertexID", "input.screenPosition",
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter Material3DLibraryTests`
Run: `swift test --package-path MetalNodesKit --filter BuiltinLibraryTests`
Expected: PASS.

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS. A palette-count assertion elsewhere (search for `NodeRegistry.builtin.all.count`) may need its number raised by 11 — that is a legitimate update; a *golden source* change is not.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Library MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): Material Output node and the ten 3D input nodes

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 3: Target-aware terminal lookup

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift:4-13, 86-100`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift:65` (the force-unwrapped `terminal`)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift`

**Interfaces:**
- Consumes: `OutputTarget.realityKit`, node id `output.material` (Tasks 1–2).
- Produces: `GraphValidator.materialTerminalID = "output.material"`; `GraphValidator.terminalID(for: OutputTarget) -> String`; `GraphValidator.terminal(in: Graph, target: OutputTarget) -> NodeID?`. The no-argument `terminal(in:)` stays as a `.fragment` convenience so existing callers compile unchanged.

Today `ShaderGenerator.generate` does `GraphValidator.terminal(in: doc.root)!` — a RealityKit document has no Fragment Output, so that force-unwrap would trap. Validation must also stop demanding a Fragment Output under `.realityKit`, and must not refuse the *other* target's terminal: switching a document's target back and forth must never make the editor delete a node.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

/// Builders shared by every material test in this suite.
enum MaterialFixture {
    /// A document whose root holds one Material Output, plus whatever `extra` adds.
    static func document(target: OutputTarget = .realityKit,
                         lighting: MaterialLightingModel = .lit,
                         _ extra: (inout Graph) -> Void = { _ in }) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = target
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        extra(&g)
        doc.root = g
        return doc
    }

    /// Adds a node of `defID` and wires its first output into the terminal's `socket`.
    @discardableResult
    static func wire(_ defID: String, into socket: String, _ g: inout Graph) -> NodeID {
        let node = NodeInstance(id: NodeID(), kind: .builtin(defID), position: .zero)
        g.nodes[node.id] = node
        let terminal = g.nodes.values.first { $0.kind == .builtin("output.material") }!
        let outName = NodeRegistry.builtin[defID]!.outputs.first!.name
        g.inputs[SocketRef(terminal.id, socket)] = SocketRef(node.id, outName)
        return node.id
    }
}

@Suite struct MaterialTerminalTests {
    @Test func theTerminalIdDependsOnTheTarget() {
        #expect(GraphValidator.terminalID(for: .fragment) == "output.fragment")
        #expect(GraphValidator.terminalID(for: .stitchable(.colorEffect)) == "output.fragment")
        #expect(GraphValidator.terminalID(for: .realityKit) == "output.material")
    }

    @Test func aRealityKitDocumentNeedsAMaterialOutput() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.root = Graph()
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(diags.contains { $0.severity == .error && $0.message.contains("Material Output") })
        #expect(!diags.contains { $0.message.contains("Fragment Output") })
    }

    @Test func twoMaterialOutputsAreRefused() {
        let doc = MaterialFixture.document { g in
            let extra = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
            g.nodes[extra.id] = extra
        }
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(diags.contains { $0.severity == .error && $0.message.contains("only one Material Output") })
    }

    /// Switching a document's target must not condemn the terminal the other target uses.
    @Test func theOtherTargetsTerminalIsIgnoredNotRefused() {
        let doc = MaterialFixture.document { g in
            let frag = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
            g.nodes[frag.id] = frag
        }
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(!diags.contains { $0.severity == .error })

        var fragmentDoc = doc
        fragmentDoc.settings.target = .fragment
        let back = GraphValidator.validate(document: fragmentDoc, registry: .builtin, target: .fragment)
        #expect(!back.contains { $0.severity == .error })
    }

    @Test func terminalLookupIsStableAcrossCalls() {
        let doc = MaterialFixture.document()
        let a = GraphValidator.terminal(in: doc.root, target: .realityKit)
        let b = GraphValidator.terminal(in: doc.root, target: .realityKit)
        #expect(a != nil)
        #expect(a == b)
        #expect(GraphValidator.terminal(in: doc.root, target: .fragment) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialTerminalTests`
Expected: FAIL — `terminalID(for:)` and `terminal(in:target:)` do not exist.

- [ ] **Step 3: Make the terminal lookup target-aware**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift`, replace the terminal constants and lookup:

```swift
public enum GraphValidator {
    public static let fragmentTerminalID = "output.fragment"
    public static let materialTerminalID = "output.material"
    static let textureSampleID = "texture.sample"

    /// Which terminal a target's program terminates at (spec §23.2). The three 2D targets share
    /// the Fragment Output; RealityKit has its own.
    public static func terminalID(for target: OutputTarget) -> String {
        switch target {
        case .fragment, .stitchable: fragmentTerminalID
        case .realityKit: materialTerminalID
        }
    }

    /// The lowest-id instance of the target's terminal, so a duplicate set always yields the same one.
    public static func terminal(in graph: Graph, target: OutputTarget) -> NodeID? {
        let id = terminalID(for: target)
        return graph.nodes.values
            .filter { $0.kind == .builtin(id) }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
            .first
    }

    /// Fragment convenience, kept so existing callers compile unchanged.
    public static func terminal(in graph: Graph) -> NodeID? { terminal(in: graph, target: .fragment) }
```

- [ ] **Step 4: Make the terminal rules target-conditional**

Still in `Validation.swift`, `validate(graph:path:document:registry:)` has no target. Give it one so the root's terminal rules can name the right node. Change the signature and both call sites in `validate(document:registry:target:)`:

```swift
    public static func validate(graph: Graph, path: GraphPath, document doc: ShaderDocument,
                                registry: NodeRegistry, target: OutputTarget = .fragment) -> [Diagnostic] {
```

Replace the `case .root:` terminal block with:

```swift
        case .root:
            let id = terminalID(for: target)
            let label = target == .realityKit ? "Material Output" : "Fragment Output"
            let terminals = sorted.filter { $0.kind == .builtin(id) }
            if terminals.isEmpty {
                out.append(Diagnostic(.error, target == .realityKit
                    ? "A RealityKit material needs a Material Output node"
                    : "Graph has no Fragment Output node"))
            }
            for extra in terminals.dropFirst() {
                out.append(Diagnostic(.error, "A graph may have only one \(label)", node: extra.id))
            }
```

The `case .definition(let gid):` block refuses `fragmentTerminalID` inside a definition. Widen it to refuse either terminal there — a Material Output inside a group definition is just as wrong:

```swift
            for n in sorted where n.kind == .builtin(fragmentTerminalID) || n.kind == .builtin(materialTerminalID) {
                let label = n.kind == .builtin(materialTerminalID) ? "Material Output" : "Fragment Output"
                out.append(Diagnostic(.error, "\(label) is only valid in the root graph", node: n.id))
            }
```

Pass the target through from the document-level entry point:

```swift
    public static func validate(document doc: ShaderDocument, registry: NodeRegistry, target: OutputTarget) -> [Diagnostic] {
        var out = validate(graph: doc.root, path: .root, document: doc, registry: registry, target: target)
        for d in doc.definitions.values.sorted(by: { $0.id.raw.uuidString < $1.id.raw.uuidString }) {
            out += validate(graph: d.graph, path: .definition(d.id), document: doc, registry: registry, target: target)
            // The self-containment check that follows is unchanged — only the two `validate(graph:…)`
            // calls above gain `target:`.
            if GroupDependencies.transitive(d.id, in: doc).contains(d.id) || GroupDependencies.direct(d).contains(d.id) {
                out.append(Diagnostic(.error, "Definition \u{201C}\(d.name)\u{201D} contains itself"))
            }
        }
        return out + textureTargetDiagnostics(doc, target: target, reachable: reachableDefinitions(doc))
    }
```

Note the existing message wording for the fragment case is preserved verbatim ("Graph has no Fragment Output node", "A graph may have only one Fragment Output") — `ValidationTests` asserts on those strings.

- [ ] **Step 5: Fix the generator's force-unwrap**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`, replace

```swift
        let terminal = GraphValidator.terminal(in: doc.root)!
```

with

```swift
        // Validation above guarantees the target's terminal exists; a RealityKit document has no
        // Fragment Output and vice versa, so the lookup must know which one to find (spec §23.2).
        let terminal = GraphValidator.terminal(in: doc.root, target: target)!
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialTerminalTests`
Run: `swift test --package-path MetalNodesKit --filter ValidationTests`
Expected: PASS. `MaterialTerminalTests` will report a *generation* failure only if you also wired the `.realityKit` codegen branch — you have not; that is Task 6. Validation is all this task gates.

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift
git commit -m "feat(core): target-aware terminal lookup for the material target

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 4: `ParamValues` — one source for a slot's current value

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/ParamValues.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/UniformImage.swift:35-53`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/ParamValuesTests.swift`

**Interfaces:**
- Consumes: nothing new.
- Produces: `ParamValues.value(for path: ParamPath, in doc: ShaderDocument, registry: NodeRegistry) -> ParamValue?` and `ParamValues.mslLiteral(_ value: ParamValue, as type: SocketType) -> String`.

`UniformImage.rebuild` already knows how to answer "what value does this `ParamPath` hold" — instance param, else the socket's `.value` default, else the param declaration's default — but it lives in `MetalNodesRender` and writes bytes. Task 6 needs the same answer as *text*. Extract the lookup into Core rather than writing it twice.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/ParamValuesTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct ParamValuesTests {
    private func documentWithAFloatNode(value: ParamValue?) -> (ShaderDocument, NodeID) {
        var doc = ShaderDocument()
        var g = Graph()
        var node = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        if let value { node.params["value"] = value }
        g.nodes[node.id] = node
        doc.root = g
        return (doc, node.id)
    }

    @Test func anInstanceValueWins() {
        let (doc, id) = documentWithAFloatNode(value: .float(2.5))
        let v = ParamValues.value(for: ParamPath(node: id, param: "value"), in: doc, registry: .builtin)
        #expect(v == .float(2.5))
    }

    @Test func theDeclarationDefaultFillsIn() {
        let (doc, id) = documentWithAFloatNode(value: nil)
        let v = ParamValues.value(for: ParamPath(node: id, param: "value"), in: doc, registry: .builtin)
        #expect(v == .float(1))   // input.float declares defaultValue .float(1)
    }

    @Test func anUnwiredInputSocketDefaultIsFound() {
        var doc = ShaderDocument()
        var g = Graph()
        let node = NodeInstance(id: NodeID(), kind: .builtin("math.mix"), position: .zero)
        g.nodes[node.id] = node
        doc.root = g
        // math.mix's `t` input has a .value default; the exact number is the declaration's.
        let declared = NodeRegistry.builtin["math.mix"]!.input(named: "t")!.default
        guard case .value(let expected) = declared else { Issue.record("math.mix.t has no value default"); return }
        let v = ParamValues.value(for: ParamPath(node: node.id, param: "t"), in: doc, registry: .builtin)
        #expect(v == expected)
    }

    @Test func aMissingNodeYieldsNil() {
        let (doc, _) = documentWithAFloatNode(value: nil)
        #expect(ParamValues.value(for: ParamPath(node: NodeID(), param: "value"), in: doc, registry: .builtin) == nil)
    }

    @Test func literalsSpellEveryUniformableType() {
        #expect(ParamValues.mslLiteral(.float(1.5), as: .float) == "1.5")
        #expect(ParamValues.mslLiteral(.float2(.init(1, 2)), as: .float2) == "float2(1.0, 2.0)")
        #expect(ParamValues.mslLiteral(.float3(.init(1, 2, 3)), as: .float3) == "float3(1.0, 2.0, 3.0)")
        #expect(ParamValues.mslLiteral(.float4(.init(1, 2, 3, 4)), as: .float4) == "float4(1.0, 2.0, 3.0, 4.0)")
        #expect(ParamValues.mslLiteral(.float4(.init(0, 0.5, 1, 1)), as: .color) == "float4(0.0, 0.5, 1.0, 1.0)")
        #expect(ParamValues.mslLiteral(.int(7), as: .int) == "7")
        #expect(ParamValues.mslLiteral(.bool(true), as: .bool) == "true")
        #expect(ParamValues.mslLiteral(.bool(false), as: .bool) == "false")
    }

    /// A literal must never lose the fractional part or emit an integer where MSL wants a float —
    /// `float3(1, 2, 3)` is legal but `float x = 1` inside a float3 constructor is a portability trap.
    @Test func floatLiteralsAlwaysCarryADecimalPoint() {
        #expect(ParamValues.mslLiteral(.float(2), as: .float) == "2.0")
        #expect(ParamValues.mslLiteral(.float3(.init(0, 0, 0)), as: .float3) == "float3(0.0, 0.0, 0.0)")
    }

    /// A value of the wrong shape for the declared type is coerced, not crashed on: a document
    /// hand-edited or migrated from an older schema must still export.
    @Test func aMismatchedValueCoercesToTheDeclaredType() {
        #expect(ParamValues.mslLiteral(.float(1), as: .float3) == "float3(1.0, 1.0, 1.0)")
        #expect(ParamValues.mslLiteral(.float3(.init(1, 2, 3)), as: .float) == "1.0")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter ParamValuesTests`
Expected: FAIL — no `ParamValues`.

- [ ] **Step 3: Write `ParamValues`**

Create `MetalNodesKit/Sources/MetalNodesCore/ParamValues.swift`:

```swift
import Foundation

/// What value a uniform slot holds right now, and how to spell it as MSL.
///
/// The lookup is the one `UniformImage.rebuild` has always used (spec §9.2): the instance's stored
/// param, else the socket's `.value` default, else the param declaration's default. It lives in
/// Core because the RealityKit export bakes the same values as literals (spec §23.6) and there
/// must be exactly one answer to "what is this slot worth".
public enum ParamValues {
    public static func value(for path: ParamPath, in doc: ShaderDocument, registry: NodeRegistry) -> ParamValue? {
        guard let nodeID = path.instancePath.first,
              let (inst, gpath) = doc.node(nodeID),
              let shape = doc.shape(of: inst, in: gpath, registry: registry) else { return nil }
        if let v = inst.params[path.param] { return v }
        if let decl = shape.input(named: path.param), case .value(let v) = decl.default { return v }
        if let p = shape.param(named: path.param) { return p.defaultValue }
        return nil
    }

    /// `value` spelled as an MSL literal of `type`. Components are coerced the way the uniform
    /// writer coerces them: a scalar splats, a longer vector truncates, a shorter one zero-fills
    /// (alpha fills with 1 for a colour).
    public static func mslLiteral(_ value: ParamValue, as type: SocketType) -> String {
        switch type {
        case .bool:
            if case .bool(let b) = value { return b ? "true" : "false" }
            return components(value).first.map { $0 != 0 ? "true" : "false" } ?? "false"
        case .int:
            if case .int(let i) = value { return "\(i)" }
            return "\(Int(components(value).first ?? 0))"
        case .float:
            return f(components(value).first ?? 0)
        case .float2:
            let c = fit(components(value), 2, fillAlpha: false)
            return "float2(\(c.map(f).joined(separator: ", ")))"
        case .float3:
            let c = fit(components(value), 3, fillAlpha: false)
            return "float3(\(c.map(f).joined(separator: ", ")))"
        case .float4, .color:
            let c = fit(components(value), 4, fillAlpha: true)
            return "float4(\(c.map(f).joined(separator: ", ")))"
        case .texture:
            return "/* texture */"
        }
    }

    /// A float that always reads as a float in MSL: never `1`, always `1.0`.
    private static func f(_ x: Float) -> String {
        let s = "\(x)"
        return s.contains(".") || s.contains("e") || s.contains("n") ? s : s + ".0"
    }

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

    /// One component splats; a short list fills with 0 (or 1 in alpha); a long one truncates.
    private static func fit(_ c: [Float], _ n: Int, fillAlpha: Bool) -> [Float] {
        if c.count == 1 { return Array(repeating: c[0], count: n) }
        if c.count >= n { return Array(c.prefix(n)) }
        var out = c
        while out.count < n { out.append(fillAlpha && out.count == 3 ? 1 : 0) }
        return out
    }
}
```

- [ ] **Step 4: Point `UniformImage.rebuild` at it**

In `MetalNodesKit/Sources/MetalNodesRender/UniformImage.swift`, replace the body of `rebuild` with the shared lookup — the byte writing stays here, only the "which value" question moves:

```swift
    /// Fresh image from the document: every field takes the instance's stored
    /// value, else the definition's default (`ParamValues`, spec §9.2).
    public static func rebuild(layout: UniformLayout, document: ShaderDocument, registry: NodeRegistry) -> UniformImage {
        var img = UniformImage(layout: layout)
        for f in layout.fields {
            guard let path = f.path,
                  let v = ParamValues.value(for: path, in: document, registry: registry) else { continue }
            img.write(v, into: f)
        }
        return img
    }
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter ParamValuesTests`
Run: `swift test --package-path MetalNodesKit --filter UniformImageTests`
Expected: PASS. `UniformImageTests` is the regression gate on the extraction — if any of its cases fail, the extracted lookup is not equivalent and the fix belongs in `ParamValues`, not in the test.

- [ ] **Step 6: Run the whole suite and commit**

Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore/ParamValues.swift \
        MetalNodesKit/Sources/MetalNodesRender/UniformImage.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/ParamValuesTests.swift
git commit -m "refactor(core): ParamValues — one answer for a slot's current value

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 5: Shared bindings and the stage partition

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift:44-125`
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift`

**Interfaces:**
- Consumes: `BuiltinNodes.materialStages`, `GraphValidator.terminal(in:target:)` (Tasks 2–3).
- Produces:
  - `Emitter.SharedBindings { let layout: UniformLayout; let textures: [AssetID?: TextureSlot]; let order: [TextureSlot] }` and a new `shared: SharedBindings? = nil` parameter on `Emitter.emit`.
  - `MaterialCodegen.stageOrder(graph:terminal:stage:) -> [NodeID]` — the nodes one stage needs, dependencies first, with the terminal last.
  - `MaterialCodegen.sharedBindings(surface:geometry:reserved:) -> Emitter.SharedBindings` — the union of two passes' requests.

Two stages must agree on one `Uniforms` struct and one texture-slot numbering: the preview program binds the same buffer to a generated vertex function and a fragment function. Each `Emitter.emit` call builds its layout from its own requests, so the passes are run twice — once to collect, once to emit against the union.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct MaterialStagePartitionTests {
    /// A document with `input.float` → baseColor and `input.float3` → positionOffset.
    private func bothStages() -> (ShaderDocument, terminal: NodeID, colorNode: NodeID, offsetNode: NodeID) {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let colorNode = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        let offsetNode = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, colorNode, offsetNode] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(colorNode.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offsetNode.id, "out")
        doc.root = g
        return (doc, terminal.id, colorNode.id, offsetNode.id)
    }

    @Test func eachStageSeesOnlyItsOwnUpstream() {
        let (doc, terminal, colorNode, offsetNode) = bothStages()
        let surface = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .geometry)
        #expect(surface.contains(colorNode))
        #expect(!surface.contains(offsetNode))
        #expect(geometry.contains(offsetNode))
        #expect(!geometry.contains(colorNode))
    }

    @Test func theTerminalIsLastInEveryStageOrder() {
        let (doc, terminal, _, _) = bothStages()
        for stage in MaterialStage.allCases {
            let order = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage)
            #expect(order.last == terminal, "\(stage)")
            #expect(order.filter { $0 == terminal }.count == 1, "\(stage)")
        }
    }

    @Test func anEmptyStageIsJustTheTerminal() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        doc.root = g
        #expect(MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry) == [terminal.id])
    }

    /// A node feeding both stages appears in both orders — it is computed once per stage,
    /// because the stages are different shader invocations that share no variables.
    @Test func aSharedNodeAppearsInBothOrders() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        let vec = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, time, vec] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(time.id, "time")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(vec.id, "out")
        doc.root = g
        let surface = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometry = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        #expect(surface.contains(time.id))
        #expect(geometry.contains(vec.id))
    }
}

@Suite struct SharedBindingsTests {
    /// Both stages must emit against one `Uniforms` struct, because the preview binds one buffer
    /// to both the generated vertex function and the fragment function.
    @Test func bothStagesEmitAgainstOneLayout() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var a = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        a.params["value"] = .float(0.25)
        var b = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        b.params["value"] = .float3(.init(1, 2, 3))
        for n in [terminal, a, b] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(a.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(b.id, "out")
        doc.root = g

        let surfaceOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let geometryOrder = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .geometry)
        func emit(_ order: [NodeID], shared: Emitter.SharedBindings?) -> Emitter.Output {
            let (resolved, diags) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
            #expect(diags.isEmpty)
            return Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                resolved: resolved, env: .fragment, shared: shared)
        }
        let shared = MaterialCodegen.sharedBindings(surface: emit(surfaceOrder, shared: nil),
                                                   geometry: emit(geometryOrder, shared: nil))
        let s = emit(surfaceOrder, shared: shared)
        let gm = emit(geometryOrder, shared: shared)
        #expect(s.layout == gm.layout)
        #expect(s.layout == shared.layout)
        // Both slots live in the one struct even though neither stage alone requests both.
        let paths = Set(shared.layout.fields.compactMap(\.path))
        #expect(paths.contains(ParamPath(node: a.id, param: "value")))
        #expect(paths.contains(ParamPath(node: b.id, param: "value")))
    }

    @Test func sharedTextureSlotsKeepTheirIndices() {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        for n in [terminal, sample] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        doc.root = g
        let order = MaterialCodegen.stageOrder(graph: g, terminal: terminal.id, stage: .surface)
        let (resolved, _) = TypeResolver.resolve(g, path: .root, document: doc, registry: .builtin, order: order)
        let first = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment)
        let shared = MaterialCodegen.sharedBindings(surface: first, geometry: first)
        let again = Emitter.emit(order: order, graph: g, path: .root, document: doc, registry: .builtin,
                                 resolved: resolved, env: .fragment, shared: shared)
        #expect(again.textureRequests == shared.order)
        #expect(again.textureRequests.first?.index == 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialStagePartition`
Expected: FAIL — `MaterialCodegen` does not exist; `Emitter.emit` has no `shared:` parameter.

- [ ] **Step 3: Add shared bindings to the emitter**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift`, add the type inside `enum Emitter`:

```swift
    /// A uniform layout and texture-slot numbering imposed from outside, so two emissions over the
    /// same document agree (spec §23.4). Without it every `emit` builds its own from its own
    /// requests, which is right for a single-program target and wrong for a two-stage one.
    struct SharedBindings {
        let layout: UniformLayout
        let textures: [AssetID?: TextureSlot]
        let order: [TextureSlot]
    }
```

Add the parameter to `emit` (last, defaulted, so no existing call site changes):

```swift
                     layerFunctions: [GroupID: GroupFunction] = [:],
                     shared: SharedBindings? = nil) -> Output {
```

Seed the texture tables from it, just above `@discardableResult func requestTexture`:

```swift
        var textureSlots: [AssetID?: TextureSlot] = shared?.textures ?? [:]
        var textureOrder: [TextureSlot] = shared?.order ?? []
```

`requestTexture` then finds every shared slot already present and never renumbers one. Finally, use the shared layout when there is one:

```swift
        var out = Output(layout: shared?.layout ?? UniformLayoutBuilder.build(requests, reserved: reserved))
        out.uniformRequests = requests
        out.textureRequests = textureOrder
```

The `Emitter.SharedBindings` type must be visible to `MaterialCodegen` in the same module — `Emitter` is `internal`, and so is the new type; that is enough. Its test access comes from `@testable import`.

- [ ] **Step 4: Write the stage partition**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift`:

```swift
import Foundation

/// The RealityKit target's code generation (spec §23.2, §23.4, §23.6). One graph, two stages:
/// this type decides what each stage needs, how the two agree on bindings, and what the exported
/// `[[visible]]` functions say.
public enum MaterialCodegen {
    /// The nodes `stage` needs, dependencies first, terminal last.
    ///
    /// A stage's roots are the terminal sockets that belong to it (`BuiltinNodes.materialStages`).
    /// Walking upstream from each root and deduplicating preserves the post-order the emitter
    /// requires. The terminal is included last so `Emitter.Output.inputExpressions[terminal]`
    /// carries the setter arguments; its own (empty) body lines are dropped by the assembler.
    public static func stageOrder(graph: Graph, terminal: NodeID, stage: MaterialStage) -> [NodeID] {
        var out: [NodeID] = []
        var seen = Set<NodeID>()
        let roots = BuiltinNodes.materialStages
            .filter { $0.value == stage }
            .keys
            .sorted()
            .compactMap { graph.inputs[SocketRef(terminal, $0)] }
            .map(\.node)
        for root in roots where graph.nodes[root] != nil {
            for id in TopoSort.order(graph, from: root) where seen.insert(id).inserted {
                out.append(id)
            }
        }
        // A wire into the terminal from the terminal itself is impossible (validation refuses
        // cycles), so the terminal can only arrive here as a duplicate of nothing.
        seen.insert(terminal)
        out.append(terminal)
        return out
    }

    /// The union of two passes' uniform and texture requests, as one layout and one slot numbering.
    /// The surface pass is numbered first so its slot indices are the stable ones.
    static func sharedBindings(surface: Emitter.Output, geometry: Emitter.Output,
                               reserved: [UniformLayoutBuilder.Reserved] = UniformLayoutBuilder.standardReserved)
        -> Emitter.SharedBindings {
        var requests: [(path: ParamPath, type: SocketType)] = []
        var seen = Set<ParamPath>()
        for r in surface.uniformRequests + geometry.uniformRequests where seen.insert(r.path).inserted {
            requests.append(r)
        }
        var slots: [AssetID?: TextureSlot] = [:]
        var order: [TextureSlot] = []
        for slot in surface.textureRequests + geometry.textureRequests where slots[slot.asset] == nil {
            let renumbered = TextureSlot(index: order.count, asset: slot.asset)
            slots[slot.asset] = renumbered
            order.append(renumbered)
        }
        return Emitter.SharedBindings(layout: UniformLayoutBuilder.build(requests, reserved: reserved),
                                      textures: slots, order: order)
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialStagePartition`
Run: `swift test --package-path MetalNodesKit --filter SharedBindings`
Expected: PASS.

- [ ] **Step 6: Run the whole suite — the emitter change must be invisible to every 2D target**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS with no golden changes. `shared` defaults to `nil`, so `.fragment` and the three stitchable targets take exactly the path they took before.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/Emitter.swift \
        MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift
git commit -m "feat(core): shared bindings and the material stage partition

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 6: The two emit environments and the exported `.metal` source

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift` (append)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift` (append)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/EmitEnvironmentTests.swift` (append)

**Interfaces:**
- Consumes: `MaterialCodegen.stageOrder`, `MaterialCodegen.sharedBindings`, `Emitter.SharedBindings` (Task 5); `ParamValues.mslLiteral` (Task 4); `BuiltinNodes.materialStages` (Task 2).
- Produces:
  - `EmitEnvironment.realityKitSurface`, `EmitEnvironment.realityKitGeometry`, and `EmitEnvironment.materialSys(for: MaterialStage) -> [String: String]`.
  - `EmitEnvironment.bakedUniforms(document:registry:) -> @Sendable (UniformField) -> String` — the uniform speller that returns a literal instead of `u.<name>`.
  - `MaterialCodegen.functionNames(exportName:) -> (surface: String, geometry: String)`.
  - `MaterialCodegen.setterStatement(socket:expression:) -> String?`.
  - `MaterialCodegen.exportSource(document:registry:surface:geometry:groupFunctions:terminal:lighting:name:) -> String`.

- [ ] **Step 1: Write the failing test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/EmitEnvironmentTests.swift`:

```swift
@Suite struct RealityKitEnvironmentTests {
    @Test func surfaceAndGeometrySpellTheirAccessors() {
        let s = EmitEnvironment.realityKitSurface.sys
        #expect(s["uv"] == "params.geometry().uv0()")
        #expect(s["time"] == "params.uniforms().time()")
        #expect(s["worldPosition"] == "params.geometry().world_position()")
        #expect(s["normal3d"] == "params.geometry().normal()")
        #expect(s["tangent"] == "params.geometry().tangent()")
        #expect(s["viewDirection"] == "params.geometry().view_direction()")
        #expect(s["screenPosition"] == "params.geometry().screen_position()")

        let g = EmitEnvironment.realityKitGeometry.sys
        #expect(g["uv"] == "geo.uv0()")
        #expect(g["time"] == "params.uniforms().time()")
        #expect(g["vertexID"] == "int(geo.vertex_id())")
        #expect(g["normal3d"] == "geo.normal()")
    }

    /// Group functions take `(float2 uv, float time, float2 size, float2 mouse, …)`, and the UV
    /// node's `aspect` variant reads `{sys.resolution}` — both keys must resolve to something
    /// even though no node can observe them as data (spec §23.4).
    @Test func resolutionAndMouseAreNeutralLiterals() {
        for env in [EmitEnvironment.realityKitSurface, EmitEnvironment.realityKitGeometry] {
            #expect(env.sys["resolution"] == "float2(1.0, 1.0)")
            #expect(env.sys["mouse"] == "float2(0.0, 0.0)")
        }
    }

    @Test func textureSamplesGoThroughTheCustomSlotAndFlipY() {
        let slot = TextureSlot(index: 0, asset: nil)
        let expr = EmitEnvironment.realityKitSurface.textureSample(slot, "uvExpr")
        #expect(expr.contains("tex0"))
        #expect(expr.contains("1.0 - "))
        // `texture2d<half>.sample` yields half4; the graph works in float4.
        #expect(expr.hasPrefix("float4("))
    }
}
```

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift`. Note the trait on the second suite: it exercises `ShaderGenerator`, which Task 9 wires, so it is **disabled here and enabled by Task 9 Step 1**. Every task must end on a green suite.

```swift
@Suite struct MaterialSetterTests {
    @Test func everySurfaceSocketMapsToItsSetterWithTheRightPrecision() {
        #expect(MaterialCodegen.setterStatement(socket: "baseColor", expression: "v0") == "surface.set_base_color(half3(v0.rgb));")
        #expect(MaterialCodegen.setterStatement(socket: "emissive", expression: "v1") == "surface.set_emissive_color(half3(v1.rgb));")
        #expect(MaterialCodegen.setterStatement(socket: "roughness", expression: "v2") == "surface.set_roughness(half(v2));")
        #expect(MaterialCodegen.setterStatement(socket: "metallic", expression: "v3") == "surface.set_metallic(half(v3));")
        #expect(MaterialCodegen.setterStatement(socket: "opacity", expression: "v4") == "surface.set_opacity(half(v4));")
        #expect(MaterialCodegen.setterStatement(socket: "occlusion", expression: "v5") == "surface.set_ambient_occlusion(half(v5));")
        #expect(MaterialCodegen.setterStatement(socket: "specular", expression: "v6") == "surface.set_specular(half(v6));")
        // The one float3 setter — tangent space, normalized by RealityKit before storing.
        #expect(MaterialCodegen.setterStatement(socket: "normal", expression: "v7") == "surface.set_normal(v7);")
        #expect(MaterialCodegen.setterStatement(socket: "positionOffset", expression: "v8") == "geo.set_model_position_offset(v8);")
        #expect(MaterialCodegen.setterStatement(socket: "nonsense", expression: "v9") == nil)
    }

    @Test func everyTerminalSocketHasASetter() {
        for decl in NodeRegistry.builtin["output.material"]!.inputs {
            #expect(MaterialCodegen.setterStatement(socket: decl.name, expression: "x") != nil, decl.name)
        }
    }

    @Test func functionNamesSuffixTheExportName() {
        let n = MaterialCodegen.functionNames(exportName: "myMaterial")
        #expect(n.surface == "myMaterial_surface")
        #expect(n.geometry == "myMaterial_geometry")
    }
}

@Suite(.disabled("enabled by Task 9, which wires the .realityKit branch into ShaderGenerator"))
struct MaterialExportSourceTests {
    /// One node wired to Base Color, one to Position Offset, one parameter to bake.
    private func document() -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "testMaterial"
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(1, 0, 0, 1))
        var offset = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        offset.params["value"] = .float3(.init(0, 0.25, 0))
        for n in [terminal, color, offset] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offset.id, "out")
        doc.root = g
        return doc
    }

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: .realityKit).exportSource ?? ""
    }

    @Test func bothFunctionsAreEmittedWithTheRealityKitHeader() throws {
        let src = try source(document())
        #expect(src.contains("#include <RealityKit/RealityKit.h>"))
        #expect(src.contains("[[visible]]\nvoid testMaterial_surface(realitykit::surface_parameters params)"))
        #expect(src.contains("[[visible]]\nvoid testMaterial_geometry(realitykit::geometry_parameters params)"))
    }

    @Test func theSurfaceFunctionSetsAllEightProperties() throws {
        let src = try source(document())
        for setter in ["set_base_color", "set_normal", "set_roughness", "set_metallic",
                       "set_emissive_color", "set_opacity", "set_ambient_occlusion", "set_specular"] {
            #expect(src.contains(setter), setter)
        }
    }

    @Test func parametersAreBakedAsLiteralsAndNoUniformBufferIsRead() throws {
        let src = try source(document())
        #expect(src.contains("float4(1.0, 0.0, 0.0, 1.0)"))
        #expect(src.contains("float3(0.0, 0.25, 0.0)"))
        #expect(!src.contains("struct Uniforms"))
        #expect(!src.contains("u."))
    }

    /// Time is the one live value: it maps natively and must not be baked.
    @Test func timeStaysLive() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let time = NodeInstance(id: NodeID(), kind: .builtin("input.time"), position: .zero)
        doc.root.nodes[time.id] = time
        doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(time.id, "time")
        #expect(try source(doc).contains("params.uniforms().time()"))
    }

    @Test func anUnwiredGeometryStageEmitsNoGeometryFunction() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        doc.root.inputs[SocketRef(terminal.id, "positionOffset")] = nil
        let src = try source(doc)
        #expect(src.contains("_surface"))
        #expect(!src.contains("_geometry"))
    }

    @Test func unlitEmitsOnlyTheEmissiveSetter() throws {
        var doc = document()
        doc.settings.lightingModel = .unlit
        let src = try source(doc)
        #expect(src.contains("set_emissive_color"))
        #expect(!src.contains("set_base_color"))
        #expect(!src.contains("set_roughness"))
    }

    @Test func aTextureSampleReadsTheCustomSlot() throws {
        var doc = document()
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        let sample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        doc.root.nodes[sample.id] = sample
        doc.root.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(sample.id, "color")
        let src = try source(doc)
        #expect(src.contains("params.textures().custom()"))
        #expect(src.contains("constexpr sampler"))
    }

    /// The generated source must be stable: same document, same bytes, every time.
    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try source(doc) == (try source(doc)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter RealityKitEnvironmentTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialSetterTests`
Expected: FAIL — the environments and `setterStatement` do not exist. `MaterialExportSourceTests` reports as skipped, not failed: it carries `.disabled(…)` because it exercises `ShaderGenerator`, which Task 9 wires. It is written now so Task 9 has a gate to satisfy.

- [ ] **Step 3: Add the two environments**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/EmitEnvironment.swift`, extend `sysNames` and add the environments:

```swift
    /// The four 2D system values plus the ten RealityKit-only ones (spec §23.3).
    public static let sysNames: Set<String> = [
        "uv", "time", "resolution", "mouse",
        "uv1", "worldPosition", "modelPosition", "normal3d", "tangent", "bitangent",
        "viewDirection", "vertexColor", "vertexID", "screenPosition",
    ]

    /// How each system value is spelled inside a RealityKit function (spec §23.3).
    ///
    /// `resolution` and `mouse` resolve to neutral literals: every group function's signature
    /// starts `(float2 uv, float time, float2 size, float2 mouse, …)` and the UV node's `aspect`
    /// variant reads `{sys.resolution}`, so the keys must produce *something*. No node can observe
    /// them — Resolution and Mouse are refused under this target — and a unit aspect ratio makes
    /// `aspect` degenerate to centred UV rather than to nonsense.
    public static func materialSys(for stage: MaterialStage) -> [String: String] {
        let geo = stage == .surface ? "params.geometry()" : "geo"
        var s: [String: String] = [
            "time": "params.uniforms().time()",
            "resolution": "float2(1.0, 1.0)",
            "mouse": "float2(0.0, 0.0)",
            "uv": "\(geo).uv0()",
            "uv1": "\(geo).uv1()",
            "worldPosition": "\(geo).world_position()",
            "modelPosition": "\(geo).model_position()",
            "normal3d": "\(geo).normal()",
            "bitangent": "\(geo).bitangent()",
            "vertexColor": "\(geo).color()",
        ]
        switch stage {
        case .surface:
            s["tangent"] = "\(geo).tangent()"
            s["viewDirection"] = "\(geo).view_direction()"
            s["screenPosition"] = "\(geo).screen_position()"
        case .geometry:
            s["vertexID"] = "int(\(geo).vertex_id())"
        }
        return s
    }

    /// `params.textures().custom()` is the only general-purpose sampler a `CustomMaterial` has
    /// (spec §23.6). It yields `half4`; the graph works in `float4`. The y flip matches the
    /// bottom-left UV convention the rest of the app uses and Apple's own USD examples.
    static func materialSample(_ slot: TextureSlot, _ uv: String) -> String {
        "float4(\(slot.fragmentName).sample(mn_sampler, float2((\(uv)).x, 1.0 - (\(uv)).y)))"
    }

    /// The surface shader: `params` is `realitykit::surface_parameters`, uniforms read `u`.
    /// `MaterialCodegen` swaps `uniform` for a literal speller when it emits the export.
    public static let realityKitSurface = EmitEnvironment(
        uniform: fragment.uniform,
        sys: materialSys(for: .surface),
        textureSample: materialSample,
        textureName: { $0.fragmentName })

    /// The geometry modifier: `geo` is `params.geometry()`, hoisted into a local by the assembler
    /// because every accessor goes through it and RealityKit's own examples do the same.
    public static let realityKitGeometry = EmitEnvironment(
        uniform: fragment.uniform,
        sys: materialSys(for: .geometry),
        textureSample: materialSample,
        textureName: { $0.fragmentName })

    /// Uniform reads spelled as the value the document holds right now (spec §23.6). Snapshotted
    /// against `layout` up front so the returned closure captures only strings and stays `Sendable`.
    public static func bakedUniforms(layout: UniformLayout, document: ShaderDocument,
                                     registry: NodeRegistry) -> @Sendable (UniformField) -> String {
        var literals: [String: String] = [:]
        for f in layout.fields {
            guard let path = f.path else { continue }
            let value = ParamValues.value(for: path, in: document, registry: registry)
            literals[f.name] = value.map { ParamValues.mslLiteral($0, as: f.type) }
                ?? ParamValues.mslLiteral(.float(0), as: f.type)
        }
        return { field in literals[field.name] ?? ParamValues.mslLiteral(.float(0), as: field.type) }
    }
```

Taking the layout up front is what keeps the closure `@Sendable`: it captures a `[String: String]`, never the document.

- [ ] **Step 4: Add the setter table and the export assembler**

Append to `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialCodegen.swift`:

```swift
public extension MaterialCodegen {
    /// `<exportName>_surface` / `<exportName>_geometry` (spec §23.6).
    static func functionNames(exportName: String) -> (surface: String, geometry: String) {
        let n = StitchableCodegen.sanitizedName(exportName)
        return ("\(n)_surface", "\(n)_geometry")
    }

    /// The RealityKit call one Material Output socket becomes.
    ///
    /// Every surface setter takes `half`/`half3`; `set_normal` is the sole `float3` one and takes a
    /// tangent-space vector. Colours arrive as `float4` from the graph and are narrowed to `half3`.
    /// Verbatim from `RealityKitSurfaceShader.h` (spec §23.2).
    static func setterStatement(socket: String, expression e: String) -> String? {
        switch socket {
        case "baseColor":      "surface.set_base_color(half3(\(e).rgb));"
        case "emissive":       "surface.set_emissive_color(half3(\(e).rgb));"
        case "normal":         "surface.set_normal(\(e));"
        case "roughness":      "surface.set_roughness(half(\(e)));"
        case "metallic":       "surface.set_metallic(half(\(e)));"
        case "opacity":        "surface.set_opacity(half(\(e)));"
        case "occlusion":      "surface.set_ambient_occlusion(half(\(e)));"
        case "specular":       "surface.set_specular(half(\(e)));"
        case "positionOffset": "geo.set_model_position_offset(\(e));"
        default: nil
        }
    }

    /// Which sockets a lighting model actually renders (spec §23.7 rule 5). `.unlit` renders only
    /// emissive, so emitting the other seven setters would be noise in the exported file.
    static func liveSurfaceSockets(_ lighting: MaterialLightingModel) -> [String] {
        switch lighting {
        case .lit: ["baseColor", "normal", "roughness", "metallic", "emissive", "opacity", "occlusion", "specular"]
        case .unlit: ["emissive"]
        }
    }
}
```

- [ ] **Step 5: Write the export assembler**

Append to `MaterialCodegen.swift`. It takes the two already-emitted stages and writes the file:

```swift
public extension MaterialCodegen {
    /// The exported `.metal`: the RealityKit header, the stdlib the graph needs, the group
    /// functions, then one `[[visible]]` function per non-empty stage (spec §23.6).
    ///
    /// `surface` and `geometry` are `Emitter.Output`s produced with `EmitEnvironment
    /// .realityKitSurface`/`.realityKitGeometry` whose `uniform` closure was replaced by
    /// `EmitEnvironment.bakedUniforms`, so no statement here reads a uniform buffer.
    static func exportSource(surface: Emitter.Output, geometry: Emitter.Output,
                             groupFunctions: [GroupFunction], terminal: NodeID,
                             lighting: MaterialLightingModel, exportName: String,
                             textures: [TextureSlot]) -> String {
        let names = functionNames(exportName: exportName)
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>")
        b.add("#include <RealityKit/RealityKit.h>")
        b.add("using namespace metal;\n")
        for f in MSLStdlib.resolve(surface.requiredStdlib + geometry.requiredStdlib
                                    + groupFunctions.flatMap(\.requiredStdlib)) {
            b.add(f.source + "\n")
        }
        for f in groupFunctions { b.add(f.source, map: f.lineMap) }

        // Surface.
        b.add("[[visible]]")
        b.add("void \(names.surface)(realitykit::surface_parameters params) {")
        // `mn_sampler` is a program-scope `constexpr sampler` supplied by the stdlib (the Texture
        // Sample node `requires` it), already emitted above — declaring another here would be a
        // redefinition.
        for slot in textures { b.add("    texture2d<half> \(slot.fragmentName) = params.textures().custom();") }
        b.add("    auto surface = params.surface();")
        for (i, line) in surface.bodyLines.enumerated() where surface.lineOwners[i] != terminal {
            b.add("    " + line, owner: surface.lineOwners[i])
        }
        for socket in liveSurfaceSockets(lighting) {
            guard let e = surface.inputExpressions[terminal]?[socket],
                  let statement = setterStatement(socket: socket, expression: e) else { continue }
            b.add("    " + statement, owner: terminal)
        }
        b.add("}")

        // Geometry — omitted entirely when nothing reaches Position Offset.
        if hasGeometryWork(geometry, terminal: terminal) {
            b.add("")
            b.add("[[visible]]")
            b.add("void \(names.geometry)(realitykit::geometry_parameters params) {")
            for slot in textures { b.add("    texture2d<half> \(slot.fragmentName) = params.textures().custom();") }
            b.add("    auto geo = params.geometry();")
            for (i, line) in geometry.bodyLines.enumerated() where geometry.lineOwners[i] != terminal {
                b.add("    " + line, owner: geometry.lineOwners[i])
            }
            if let e = geometry.inputExpressions[terminal]?["positionOffset"],
               let statement = setterStatement(socket: "positionOffset", expression: e) {
                b.add("    " + statement, owner: terminal)
            }
            b.add("}")
        }
        return b.text
    }

    /// True when the geometry stage does anything but restate its default: some node reaches
    /// Position Offset. An offset left at its slot default moves nothing, and emitting a modifier
    /// that adds a constant zero would cost the caller a `boundsMargin` conversation for nothing.
    static func hasGeometryWork(_ geometry: Emitter.Output, terminal: NodeID) -> Bool {
        geometry.lineOwners.contains { $0 != nil && $0 != terminal }
    }
}
```

`liveSurfaceSockets` under `.unlit` returns only `emissive`, which is also why the unlit test asserts the absence of `set_base_color`.

- [ ] **Step 6: Run the environment and setter tests**

Run: `swift test --package-path MetalNodesKit --filter RealityKitEnvironmentTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialSetterTests`
Expected: PASS. `MaterialExportSourceTests` reports skipped.

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS, with `MaterialExportSourceTests` reported as skipped. A *failing* case here is a real defect, not the expected gate.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): RealityKit emit environments, setter table and export source

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 7: Validation rules 2–5

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift:16-27` (document-level entry point)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift` (append)

**Interfaces:**
- Consumes: `MaterialCodegen.stageOrder`, `NodeDef.stages`, `GraphValidator.reachableDefinitions`, `BuiltinNodes.materialStages`.
- Produces: `MaterialValidation.diagnostics(document:registry:target:reachable:) -> [Diagnostic]`, called from `GraphValidator.validate(document:registry:target:)` alongside `textureTargetDiagnostics`.

The four rules: **stage legality** (a node whose `stages` omits the stage that reaches it), **target legality** (Mouse/Resolution under `.realityKit`, and a 3D node under any other target), **texture count** (at most one Texture Sample), **lighting model** (a warning when `.unlit` and a non-emissive socket is wired).

- [ ] **Step 1: Write the failing test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift`:

```swift
@Suite struct MaterialRuleTests {
    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
            .filter { $0.severity == .error }
    }
    private func warnings(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
            .filter { $0.severity == .warning }
    }

    // Rule 2 — stage legality.

    @Test func aSurfaceOnlyNodeInTheGeometryStageIsRefused() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.viewDirection", into: "positionOffset", &g)
        }
        #expect(errors(doc).contains { $0.message.contains("View Direction") && $0.message.contains("geometry") })
    }

    @Test func aGeometryOnlyNodeInTheSurfaceStageIsRefused() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.vertexID", into: "roughness", &g)
        }
        #expect(errors(doc).contains { $0.message.contains("Vertex ID") && $0.message.contains("surface") })
    }

    @Test func aStageAgnosticNodeIsFineInBoth() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.worldPosition", into: "positionOffset", &g)
            MaterialFixture.wire("input.modelPosition", into: "baseColor", &g)
        }
        #expect(errors(doc).isEmpty)
    }

    @Test func aSurfaceOnlyNodeInItsOwnStageIsFine() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.tangent", into: "normal", &g)
        }
        #expect(errors(doc).isEmpty)
    }

    // Rule 3 — target legality.

    @Test func mouseAndResolutionAreRefusedUnderRealityKit() {
        for id in ["input.mouse", "input.resolution"] {
            let doc = MaterialFixture.document { g in MaterialFixture.wire(id, into: "baseColor", &g) }
            #expect(errors(doc).contains { $0.message.contains("Fragment or SwiftUI target") }, id)
        }
    }

    @Test func aThreeDimensionalNodeIsRefusedUnderTheFragmentTarget() {
        var doc = ShaderDocument()
        doc.settings.target = .fragment
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let normal = NodeInstance(id: NodeID(), kind: .builtin("input.normal3d"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[normal.id] = normal
        doc.root = g
        #expect(errors(doc).contains { $0.message.contains("RealityKit Material target") })
    }

    @Test func aThreeDimensionalNodeIsFineUnderRealityKit() {
        let doc = MaterialFixture.document { g in MaterialFixture.wire("input.normal3d", into: "normal", &g) }
        #expect(errors(doc).isEmpty)
    }

    // Rule 4 — one texture slot.

    @Test func oneTextureSampleIsAllowedAndTwoAreNot() {
        let one = MaterialFixture.document { g in MaterialFixture.wire("texture.sample", into: "baseColor", &g) }
        #expect(errors(one).isEmpty)

        let two = MaterialFixture.document { g in
            MaterialFixture.wire("texture.sample", into: "baseColor", &g)
            MaterialFixture.wire("texture.sample", into: "emissive", &g)
        }
        let diags = errors(two)
        #expect(diags.contains { $0.message.contains("one texture slot") })
        // Anchored on the extra sample, not on the first — the first is the one to keep.
        #expect(diags.first { $0.message.contains("one texture slot") }?.node != nil)
    }

    @Test func aTextureSampleInsideAGroupIsRefused() throws {
        var doc = MaterialFixture.document()
        var def = GroupDefinition(id: GroupID(), name: "Sampler")
        var inner = Graph()
        for kind in [NodeKind.groupInput, .groupOutput, .builtin("texture.sample")] {
            let n = NodeInstance(id: NodeID(), kind: kind, position: .zero)
            inner.nodes[n.id] = n
        }
        def.graph = inner
        doc.definitions[def.id] = def
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        doc.root.nodes[instance.id] = instance
        #expect(errors(doc).contains { $0.message.contains("samples its texture in the root graph") })
    }

    // Rule 5 — lighting model warning.

    @Test func unlitWarnsWhenANonEmissiveSocketIsWired() {
        let doc = MaterialFixture.document(lighting: .unlit) { g in
            MaterialFixture.wire("input.color", into: "baseColor", &g)
        }
        #expect(warnings(doc).contains { $0.message.contains("only Emissive") })
        #expect(errors(doc).isEmpty)   // a warning, never an error
    }

    @Test func unlitIsSilentWhenOnlyEmissiveIsWired() {
        let doc = MaterialFixture.document(lighting: .unlit) { g in
            MaterialFixture.wire("input.color", into: "emissive", &g)
        }
        #expect(warnings(doc).isEmpty)
    }

    @Test func litNeverWarnsAboutSockets() {
        let doc = MaterialFixture.document(lighting: .lit) { g in
            MaterialFixture.wire("input.color", into: "baseColor", &g)
        }
        #expect(warnings(doc).isEmpty)
    }

    /// Rules must see inside group definitions the root actually instantiates — that is what
    /// `reachableDefinitions` is for, and a stage-illegal node hidden in a group is still illegal.
    @Test func aStageIllegalNodeInsideAReachableGroupIsRefused() throws {
        var doc = MaterialFixture.document()
        var def = GroupDefinition(id: GroupID(), name: "Inner")
        var inner = Graph()
        let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
        let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        for n in [gin, gout, vid] { inner.nodes[n.id] = n }
        def.graph = inner
        doc.definitions[def.id] = def
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        doc.root.nodes[instance.id] = instance
        // Vertex ID is geometry-only; the instance is reachable from the surface stage's root.
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        if let out = def.outputs.first {
            doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(instance.id, out.name)
        }
        #expect(errors(doc).contains { $0.message.contains("Vertex ID") })
    }
}
```

If `GroupDefinition`'s initializer or `outputs` shape differs from the sketch above, adapt the fixture to the real API — read `MetalNodesCore/GroupDefinition.swift` first. The assertion (a stage-illegal node inside a reachable definition is refused) is the requirement; the construction is incidental.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialRuleTests`
Expected: FAIL — no rule produces any of these diagnostics.

- [ ] **Step 3: Write the rules**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialValidation.swift`:

```swift
import Foundation

/// The four rules the RealityKit target adds beyond the terminal rules (spec §23.7). They live
/// apart from `GraphValidator` because they are the only rules that reason about stages, and
/// `Validation.swift` is long enough already.
public enum MaterialValidation {
    /// Rules 2–5. Rule 1 (the terminal) is `GraphValidator`'s, because every target has one.
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry,
                                   target: OutputTarget, reachable: [GroupDefinition]) -> [Diagnostic] {
        guard target == .realityKit else { return foreignNodeDiagnostics(doc, registry: registry, reachable: reachable) }
        guard let terminal = GraphValidator.terminal(in: doc.root, target: .realityKit) else { return [] }
        return stageDiagnostics(doc, registry: registry, terminal: terminal, reachable: reachable)
            + targetDiagnostics(doc, registry: registry, reachable: reachable)
            + textureDiagnostics(doc, reachable: reachable)
            + lightingDiagnostics(doc, terminal: terminal)
    }

    /// Every node of the root and of a reachable definition, each with the graph it lives in.
    private static func allNodes(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [(NodeInstance, Graph)] {
        var out = doc.root.nodes.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .map { ($0, doc.root) }
        for d in reachable {
            out += d.graph.nodes.values
                .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                .map { ($0, d.graph) }
        }
        return out
    }

    private static func title(_ inst: NodeInstance, _ doc: ShaderDocument, _ registry: NodeRegistry) -> String {
        if case .builtin(let id) = inst.kind, let def = registry[id] { return inst.customTitle ?? def.title }
        return inst.customTitle ?? "Node"
    }

    // MARK: Rule 2 — stage legality

    /// A node whose `stages` omits the stage that reaches it. Reachability inside a definition is
    /// coarse on purpose: a definition is attributed to every stage that instantiates it, because
    /// one function body serves both callers.
    private static func stageDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry, terminal: NodeID,
                                         reachable: [GroupDefinition]) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for stage in MaterialStage.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let order = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage)
            var toVisit: [(NodeInstance, Graph)] = order.compactMap { id in
                doc.root.nodes[id].map { ($0, doc.root) }
            }
            var visitedDefinitions = Set<GroupID>()
            var i = 0
            while i < toVisit.count {
                let (inst, _) = toVisit[i]; i += 1
                switch inst.kind {
                case .builtin(let id):
                    guard let def = registry[id], !def.stages.contains(stage) else { continue }
                    out.append(Diagnostic(.error,
                        "\(title(inst, doc, registry)) is not available in the \(stage.title) stage",
                        node: inst.id))
                case .group(let gid):
                    guard visitedDefinitions.insert(gid).inserted, let d = doc.definitions[gid] else { continue }
                    toVisit += d.graph.nodes.values
                        .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                        .map { ($0, d.graph) }
                case .groupInput, .groupOutput:
                    continue
                }
            }
        }
        return out
    }

    // MARK: Rule 3 — target legality

    /// Nodes that read a system value this target cannot supply.
    private static let twoDimensionalOnly: Set<String> = ["input.mouse", "input.resolution"]

    private static func targetDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                          reachable: [GroupDefinition]) -> [Diagnostic] {
        allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, twoDimensionalOnly.contains(id) else { return nil }
            return Diagnostic(.error, "\(title(inst, doc, registry)) needs the Fragment or SwiftUI target", node: inst.id)
        }
    }

    /// The mirror rule: a node that only RealityKit can emit, reachable under another target.
    /// Applies to every target *but* `.realityKit`, which is why it sits outside the guard above.
    private static func foreignNodeDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                               reachable: [GroupDefinition]) -> [Diagnostic] {
        let materialOnly = Set(BuiltinNodes.material3D.map(\.id)).subtracting(["output.material"])
        return allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, materialOnly.contains(id) else { return nil }
            return Diagnostic(.error, "\(title(inst, doc, registry)) needs the RealityKit Material target", node: inst.id)
        }
    }

    // MARK: Rule 4 — one texture slot

    private static func textureDiagnostics(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // A group function declares its texture parameters as `texture2d<float>` (spec §21.2), and
        // `params.textures().custom()` is a `texture2d<half>` — MSL converts neither. Rather than
        // fork the group-function signature per target for one slot, this target samples from the
        // root only. The same shape as M3's refusal, which M6 lifted for the Layer Effect.
        for d in reachable {
            for id in d.graph.nodes.values
                .filter({ $0.kind == .builtin("texture.sample") })
                .map(\.id)
                .sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
                out.append(Diagnostic(.error,
                    "A RealityKit material samples its texture in the root graph — move this Texture Sample out of the group",
                    node: id))
            }
        }

        let samples = doc.root.nodes.values
            .filter { $0.kind == .builtin("texture.sample") }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
        out += samples.dropFirst().map {
            Diagnostic(.error, "A RealityKit material has one texture slot — remove the extra Texture Sample", node: $0)
        }
        return out
    }

    // MARK: Rule 5 — lighting model

    private static func lightingDiagnostics(_ doc: ShaderDocument, terminal: NodeID) -> [Diagnostic] {
        guard doc.settings.lightingModel == .unlit else { return [] }
        let wired = BuiltinNodes.materialStages.keys
            .filter { $0 != "emissive" && doc.root.inputs[SocketRef(terminal, $0)] != nil }
        guard !wired.isEmpty else { return [] }
        return [Diagnostic(.warning, "Unlit materials render only Emissive", node: terminal)]
    }
}
```

- [ ] **Step 4: Call the rules**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/Validation.swift`, the document-level entry point's last line becomes:

```swift
        let reachable = reachableDefinitions(doc)
        return out + textureTargetDiagnostics(doc, target: target, reachable: reachable)
                   + MaterialValidation.diagnostics(document: doc, registry: registry, target: target, reachable: reachable)
```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialRuleTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialTerminalTests`
Expected: PASS.

- [ ] **Step 6: Run the whole suite**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS except `MaterialExportSourceTests` (Task 9's gate). The new foreign-node rule touches the 2D targets — if an existing test document happens to contain a 3D node it will now be refused, but none can, because Task 2 introduced those nodes and no fixture uses them.

- [ ] **Step 7: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen MetalNodesKit/Tests/MetalNodesCoreTests/MaterialValidationTests.swift
git commit -m "feat(core): stage, target, texture and lighting validation rules

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 8: The 3D preview program

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift`

**Interfaces:**
- Consumes: `Emitter.Output`, `MaterialCodegen.setterStatement` is *not* used here (the preview shades in-line), `MaterialLightingModel`, `UniformLayout`, `TextureSlot`.
- Produces:
  - `MaterialPreviewCodegen.vertexFunctionName = "mn_meshVertex"`.
  - `MaterialPreviewCodegen.program(surface:geometry:groupFunctions:terminal:layout:lighting:textures:) -> SourceBuilder` — a complete vertex+fragment MSL program.
  - `MaterialPreviewCodegen.meshVertexStruct`, `.cameraStruct`, `.interpolantsStruct` — the shared struct text, so the Render target's Swift structs can be checked against them.

The program's shape, top to bottom: includes, `Uniforms`, `MeshVertex`, `CameraUniforms`, `VertexOut`, the stdlib, the group functions, the generated vertex function, the GGX helpers, `shaderMain`.

Buffer bindings, fixed by spec §23.5: vertex 0 = vertices, vertex 1 = camera, vertex 2 = uniforms; fragment 0 = uniforms, fragment 1 = camera. Textures keep their slot indices in both stages.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite(.disabled("enabled by Task 9, which wires the .realityKit branch into ShaderGenerator"))
struct MaterialPreviewCodegenTests {
    private func document(lighting: MaterialLightingModel = .lit, offset: Bool = true) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(0, 1, 0, 1))
        g.nodes[terminal.id] = terminal
        g.nodes[color.id] = color
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        if offset {
            let v = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[v.id] = v
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(v.id, "out")
        }
        doc.root = g
        return doc
    }

    private func source(_ doc: ShaderDocument) throws -> String {
        try ShaderGenerator.generate(doc, target: .realityKit).source
    }

    @Test func theProgramHasBothStagesAndNoRealityKitHeader() throws {
        let src = try source(document())
        #expect(src.contains("vertex VertexOut mn_meshVertex("))
        #expect(src.contains("fragment float4 shaderMain("))
        // Those headers ship with Xcode, not with the OS; the runtime compiler cannot find them.
        #expect(!src.contains("RealityKit"))
        #expect(!src.contains("[[visible]]"))
    }

    @Test func bufferIndicesMatchTheSpec() throws {
        let src = try source(document())
        #expect(src.contains("device const MeshVertex *verts [[buffer(0)]]"))
        #expect(src.contains("constant CameraUniforms &cam [[buffer(1)]]"))
        #expect(src.contains("constant Uniforms &u [[buffer(2)]]"))     // vertex stage
        #expect(src.contains("constant Uniforms &u [[buffer(0)]]"))     // fragment stage
        #expect(src.contains("constant CameraUniforms &cam [[buffer(1)]]"))
    }

    @Test func theGeometryStageRunsInTheVertexFunction() throws {
        let src = try source(document(offset: true))
        let vertexRange = try #require(src.range(of: "vertex VertexOut mn_meshVertex("))
        let fragmentRange = try #require(src.range(of: "fragment float4 shaderMain("))
        let vertexBody = String(src[vertexRange.lowerBound..<fragmentRange.lowerBound])
        #expect(vertexBody.contains("positionOffset") || vertexBody.contains("offset"))
        #expect(vertexBody.contains("cam.viewToProjection"))
    }

    @Test func withoutAGeometryStageTheVertexFunctionStillExists() throws {
        let src = try source(document(offset: false))
        #expect(src.contains("vertex VertexOut mn_meshVertex("))
    }

    @Test func litShadesWithGGXAndUnlitDoesNot() throws {
        let lit = try source(document(lighting: .lit))
        #expect(lit.contains("mn_ggx_distribution"))
        #expect(lit.contains("mn_smith_visibility"))
        #expect(lit.contains("mn_schlick_fresnel"))

        let unlit = try source(document(lighting: .unlit))
        #expect(!unlit.contains("mn_ggx_distribution"))
        #expect(unlit.contains("emissive"))
    }

    /// The tangent-space normal socket must be resolved against the interpolated basis before it
    /// can shade — otherwise a wired Normal produces a lit sphere that ignores it.
    @Test func theNormalSocketIsResolvedThroughTheTangentBasis() throws {
        let src = try source(document())
        #expect(src.contains("float3x3(") && src.contains("tangent"))
    }

    @Test func theStructsMatchTheirDeclaredLayout() throws {
        let src = try source(document())
        #expect(src.contains(MaterialPreviewCodegen.meshVertexStruct))
        #expect(src.contains(MaterialPreviewCodegen.cameraStruct))
        #expect(src.contains("struct Uniforms {"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document()
        #expect(try source(doc) == (try source(doc)))
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialPreviewCodegenTests`
Expected: FAIL to compile — `MaterialPreviewCodegen` does not exist. Once Step 3 defines it the suite compiles and reports **skipped**, because it carries `.disabled(…)`: it exercises `ShaderGenerator`, which Task 9 wires.

- [ ] **Step 3: Write the shared struct text**

Create `MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift`:

```swift
import Foundation

/// The 3D preview program (spec §23.5): a *generated* vertex stage so a geometry modifier is
/// visible, and a fragment stage that runs the surface statements and shades them with a
/// Cook-Torrance GGX approximation of RealityKit's `.lit` model.
///
/// The approximation is deliberate and documented: the preview shows the material's shape, not
/// RealityKit's exact output. One fixed key light plus a constant hemispheric ambient.
public enum MaterialPreviewCodegen {
    public static let vertexFunctionName = "mn_meshVertex"

    /// Mirrors `MetalNodesRender.MeshVertex` byte for byte. Both sides are checked against this
    /// text: the Swift struct's `MemoryLayout` in `MeshBuilderTests`, the MSL here.
    public static let meshVertexStruct = """
    struct MeshVertex {
        float3 position;
        float3 normal;
        float4 tangent;
        float2 uv;
        float4 color;
    };
    """

    /// Mirrors `MetalNodesRender.CameraUniforms`.
    public static let cameraStruct = """
    struct CameraUniforms {
        float4x4 modelToWorld;
        float4x4 worldToView;
        float4x4 viewToProjection;
        float3x3 normalToWorld;
        float3 cameraPosition;
    };
    """

    public static let interpolantsStruct = """
    struct VertexOut {
        float4 position [[position]];
        float3 worldPosition;
        float3 modelPosition;
        float3 normal;
        float3 tangent;
        float3 bitangent;
        float3 viewDirection;
        float2 uv;
        float4 color;
    };
    """

    /// GGX distribution, Smith height-correlated visibility, Schlick Fresnel, Lambert diffuse.
    static let shadingHelpers = """
    static inline float mn_ggx_distribution(float ndoth, float a) {
        float a2 = a * a;
        float d = ndoth * ndoth * (a2 - 1.0) + 1.0;
        return a2 / max(3.14159265 * d * d, 1e-6);
    }

    static inline float mn_smith_visibility(float ndotv, float ndotl, float a) {
        float a2 = a * a;
        float v = ndotl * sqrt(ndotv * ndotv * (1.0 - a2) + a2);
        float l = ndotv * sqrt(ndotl * ndotl * (1.0 - a2) + a2);
        return 0.5 / max(v + l, 1e-6);
    }

    static inline float3 mn_schlick_fresnel(float3 f0, float vdoth) {
        return f0 + (1.0 - f0) * pow(saturate(1.0 - vdoth), 5.0);
    }
    """
}
```

- [ ] **Step 4: Write the vertex function**

Append to `MaterialPreviewCodegen.swift`:

```swift
extension MaterialPreviewCodegen {
    /// The generated vertex stage. It reads `MeshVertex` by `[[vertex_id]]` — no vertex descriptor —
    /// runs the geometry stage's statements, adds the resulting model-space offset, and interpolates
    /// everything the surface stage can read.
    static func vertexFunction(geometry: Emitter.Output, terminal: NodeID,
                               textures: [TextureSlot]) -> [(line: String, owner: NodeID?)] {
        var out: [(String, NodeID?)] = []
        func add(_ l: String, _ o: NodeID? = nil) { out.append((l, o)) }
        add("    MeshVertex vert = verts[vid];")
        add("    float3 offset = float3(0.0);")
        // The statements run against a local `geo` shim whose accessors are the mesh vertex's own
        // fields, so `EmitEnvironment.realityKitGeometry`'s `geo.…()` spellings compile unchanged.
        add("    MNGeometry geo = MNGeometry{ vert, cam, vid };")
        for (i, line) in geometry.bodyLines.enumerated() where geometry.lineOwners[i] != terminal {
            add("    " + line, geometry.lineOwners[i])
        }
        if let e = geometry.inputExpressions[terminal]?["positionOffset"] {
            add("    offset = \(e);", terminal)
        }
        add("    float3 modelPosition = vert.position + offset;")
        add("    float4 world = cam.modelToWorld * float4(modelPosition, 1.0);")
        add("    VertexOut o;")
        add("    o.position = cam.viewToProjection * (cam.worldToView * world);")
        add("    o.worldPosition = world.xyz;")
        add("    o.modelPosition = modelPosition;")
        add("    o.normal = normalize(cam.normalToWorld * vert.normal);")
        add("    o.tangent = normalize(cam.normalToWorld * vert.tangent.xyz);")
        add("    o.bitangent = cross(o.normal, o.tangent) * vert.tangent.w;")
        add("    o.viewDirection = normalize(cam.cameraPosition - world.xyz);")
        add("    o.uv = vert.uv;")
        add("    o.color = vert.color;")
        add("    return o;")
        return out.map { (line: $0.0, owner: $0.1) }
    }

    /// The shim the geometry statements read. Its accessor names match
    /// `EmitEnvironment.materialSys(for: .geometry)` exactly, so one emission serves both the
    /// export (where `geo` is RealityKit's) and the preview (where `geo` is this).
    static let geometryShim = """
    struct MNGeometry {
        MeshVertex v;
        constant CameraUniforms &cam;
        uint vid;
        float3 model_position() const { return v.position; }
        float3 world_position() const { return (cam.modelToWorld * float4(v.position, 1.0)).xyz; }
        float3 normal() const { return v.normal; }
        float3 bitangent() const { return cross(v.normal, v.tangent.xyz) * v.tangent.w; }
        float2 uv0() const { return v.uv; }
        float2 uv1() const { return v.uv; }
        float4 color() const { return v.color; }
        uint vertex_id() const { return vid; }
    };
    """
}
```

`MNGeometry` holds a reference member, so it is constructed with the brace initializer shown, never default-constructed. If the Metal compiler rejects the reference member, change it to `constant CameraUniforms *cam;` and dereference — verify with the GPU compile test in Task 12 before shipping either form.

- [ ] **Step 5: Write the fragment function and assemble the program**

Append to `MaterialPreviewCodegen.swift`:

```swift
extension MaterialPreviewCodegen {
    /// The whole preview program.
    public static func program(surface: Emitter.Output, geometry: Emitter.Output,
                               groupFunctions: [GroupFunction], terminal: NodeID,
                               layout: UniformLayout, lighting: MaterialLightingModel,
                               textures: [TextureSlot], viewerExpression: String? = nil) -> SourceBuilder {
        var b = SourceBuilder()
        b.add("#include <metal_stdlib>\nusing namespace metal;\n")
        b.add(layout.mslStruct + "\n")
        b.add(meshVertexStruct + "\n")
        b.add(cameraStruct + "\n")
        b.add(geometryShim + "\n")
        b.add(interpolantsStruct + "\n")
        b.add(surfaceShim + "\n")
        for f in MSLStdlib.resolve(surface.requiredStdlib + geometry.requiredStdlib
                                    + groupFunctions.flatMap(\.requiredStdlib)) {
            b.add(f.source + "\n")
        }
        if lighting == .lit { b.add(shadingHelpers + "\n") }
        for f in groupFunctions { b.add(f.source, map: f.lineMap) }

        // Vertex stage.
        var vertexParams = ["uint vid [[vertex_id]]",
                            "device const MeshVertex *verts [[buffer(0)]]",
                            "constant CameraUniforms &cam [[buffer(1)]]",
                            "constant Uniforms &u [[buffer(2)]]"]
        vertexParams += textures.map { "texture2d<float> \($0.fragmentName) [[texture(\($0.index))]]" }
        b.add("vertex VertexOut \(vertexFunctionName)(" + vertexParams.joined(separator: ",\n" + String(repeating: " ", count: 24)) + ") {")
        for s in vertexFunction(geometry: geometry, terminal: terminal, textures: textures) {
            b.add(s.line, owner: s.owner)
        }
        b.add("}\n")

        // Fragment stage.
        var fragmentParams = ["VertexOut in [[stage_in]]",
                              "constant Uniforms &u [[buffer(0)]]",
                              "constant CameraUniforms &cam [[buffer(1)]]"]
        fragmentParams += textures.map { "texture2d<float> \($0.fragmentName) [[texture(\($0.index))]]" }
        b.add("fragment float4 \(ShaderGenerator.fragmentFunctionName)(" + fragmentParams.joined(separator: ",\n" + String(repeating: " ", count: 25)) + ") {")
        for line in fragmentBody(surface: surface, terminal: terminal, lighting: lighting,
                                 viewerExpression: viewerExpression) {
            b.add(line.line, owner: line.owner)
        }
        b.add("}")
        return b
    }

    /// The surface statements, the eight material values, then the shading.
    static func fragmentBody(surface: Emitter.Output, terminal: NodeID,
                             lighting: MaterialLightingModel) -> [(line: String, owner: NodeID?)] {
        var out: [(String, NodeID?)] = []
        func add(_ l: String, _ o: NodeID? = nil) { out.append((l, o)) }
        // `params` in the surface environment is RealityKit's; here the same accessor names are
        // served by a shim built from the interpolants.
        add("    MNSurface params = MNSurface{ in, cam, u };")
        for (i, line) in surface.bodyLines.enumerated() where surface.lineOwners[i] != terminal {
            add("    " + line, surface.lineOwners[i])
        }
        let e = surface.inputExpressions[terminal] ?? [:]
        func value(_ socket: String, _ fallback: String) -> String { e[socket] ?? fallback }
        add("    float4 baseColor = \(value("baseColor", "float4(0.8, 0.8, 0.8, 1.0)"));", terminal)
        add("    float4 emissive = \(value("emissive", "float4(0.0, 0.0, 0.0, 1.0)"));", terminal)
        add("    float opacity = \(value("opacity", "1.0"));", terminal)
        guard lighting == .lit else {
            add("    return float4(emissive.rgb, opacity);", terminal)
            return out.map { (line: $0.0, owner: $0.1) }
        }
        add("    float3 tangentNormal = \(value("normal", "float3(0.0, 0.0, 1.0)"));", terminal)
        add("    float roughness = clamp(\(value("roughness", "0.5")), 0.03, 1.0);", terminal)
        add("    float metallic = saturate(\(value("metallic", "0.0")));", terminal)
        add("    float occlusion = saturate(\(value("occlusion", "1.0")));", terminal)
        add("    float specular = saturate(\(value("specular", "0.5")));", terminal)
        add("    float3x3 basis = float3x3(normalize(in.tangent), normalize(in.bitangent), normalize(in.normal));")
        add("    float3 n = normalize(basis * normalize(tangentNormal));")
        add("    float3 v = normalize(cam.cameraPosition - in.worldPosition);")
        add("    float3 l = normalize(float3(0.5, 0.8, 0.6));")
        add("    float3 h = normalize(v + l);")
        add("    float ndotl = saturate(dot(n, l));")
        add("    float ndotv = saturate(dot(n, v)) + 1e-5;")
        add("    float a = roughness * roughness;")
        add("    float3 f0 = mix(float3(0.08 * specular), baseColor.rgb, metallic);")
        add("    float3 spec = mn_schlick_fresnel(f0, saturate(dot(v, h)))")
        add("                * mn_ggx_distribution(saturate(dot(n, h)), a)")
        add("                * mn_smith_visibility(ndotv, ndotl, a);")
        add("    float3 diffuse = baseColor.rgb * (1.0 - metallic) / 3.14159265;")
        add("    float3 direct = (diffuse + spec) * ndotl * 3.0;")
        add("    float3 ambient = baseColor.rgb * (1.0 - metallic) * 0.12 * occlusion;")
        add("    return float4(direct + ambient + emissive.rgb, opacity);", terminal)
        return out.map { (line: $0.0, owner: $0.1) }
    }

    /// The surface shim: RealityKit's `params.geometry().x()` accessors served from interpolants.
    static let surfaceShim = """
    struct MNSurfaceGeometry {
        VertexOut in;
        float3 world_position() const { return in.worldPosition; }
        float3 model_position() const { return in.modelPosition; }
        float3 normal() const { return in.normal; }
        float3 tangent() const { return in.tangent; }
        float3 bitangent() const { return in.bitangent; }
        float2 uv0() const { return in.uv; }
        float2 uv1() const { return in.uv; }
        float4 color() const { return in.color; }
        float4 screen_position() const { return in.position; }
        float3 view_direction() const { return in.viewDirection; }
    };
    struct MNSurfaceUniforms {
        constant Uniforms &u;
        float time() const { return u.time; }
    };
    struct MNSurface {
        VertexOut in;
        constant CameraUniforms &cam;
        constant Uniforms &u;
        MNSurfaceGeometry geometry() const { return MNSurfaceGeometry{ in }; }
        MNSurfaceUniforms uniforms() const { return MNSurfaceUniforms{ u }; }
    };
    """
}
```

Every accessor name here matches `EmitEnvironment.materialSys(for: .surface)` exactly — `view_direction()` sits on `geometry()` because that is where RealityKit puts it. That identity is the whole point of the shims: one emission serves both the export (where `params` is RealityKit's) and the preview (where it is this).

Add `surfaceShim` to `program(...)`'s preamble, immediately after `interpolantsStruct` — it names `VertexOut`, so it must follow it.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialPreviewCodegenTests`
Expected: the suite compiles and reports **skipped**. Everything it asserts about the generated text is Task 9's acceptance gate.

Run: `swift test --package-path MetalNodesKit`
Expected: PASS — no failures, two suites skipped.

- [ ] **Step 7: Verify the module builds warning-free**

Run: `swift build --package-path MetalNodesKit 2>&1 | grep -i warning; echo "exit=$?"`
Expected: no warning lines.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Codegen/MaterialPreviewCodegen.swift \
        MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift
git commit -m "feat(core): the 3D preview program — generated vertex stage and GGX shading

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 9: Wire the target into `ShaderGenerator`

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift:3-38` (`GeneratedShader` fields), `:96-108` (the target switch), plus a new `assembleRealityKit`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift` (`MaterialExportSourceTests`, written in Task 6)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift` (written in Task 8)

**Interfaces:**
- Consumes: everything from Tasks 5, 6 and 8.
- Produces: `GeneratedShader.stageFunctionNames: [MaterialStage: String]` (empty for every other target) and `GeneratedShader.vertexFunctionName: String` (defaults to `VertexStage.functionName`, which `MetalNodesCore` names as the string literal `"mn_fullscreenVertex"` — Core cannot import Render). `ShaderGenerator.generate(_:target:…)` accepts `.realityKit`.

This is the task that turns eighteen already-written tests green.

- [ ] **Step 1: Enable the two gate suites**

Tasks 6 and 8 wrote their acceptance suites with a `.disabled(…)` trait so those tasks could end on a green suite. Remove both traits now — they are this task's gate.

In `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialCodegenTests.swift`:

```swift
@Suite struct MaterialExportSourceTests {
```

In `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift`:

```swift
@Suite struct MaterialPreviewCodegenTests {
```

Run: `swift test --package-path MetalNodesKit --filter MaterialExportSourceTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialPreviewCodegenTests`
Expected: FAIL, every case, at `ShaderGenerator.generate(doc, target: .realityKit)`. That is what the rest of this task fixes.

- [ ] **Step 2: Extend `GeneratedShader`**

In `MetalNodesKit/Sources/MetalNodesCore/Codegen/ShaderGenerator.swift`:

```swift
    /// The exported `[[visible]]` function per stage, when `target` is `.realityKit` (spec §23.4).
    /// Empty for every other target. A stage with nothing to do has no entry.
    public let stageFunctionNames: [MaterialStage: String]
    /// The vertex function the pipeline pairs with `fragmentFunctionName`. The static fullscreen
    /// triangle for every 2D program; a generated one for the 3D preview (spec §23.5).
    public let vertexFunctionName: String
```

and in the initializer, after `textures`:

```swift
                textures: [TextureSlot] = [], stageFunctionNames: [MaterialStage: String] = [:],
                vertexFunctionName: String = "mn_fullscreenVertex") {
        …
        self.stageFunctionNames = stageFunctionNames
        self.vertexFunctionName = vertexFunctionName
    }
```

`MetalNodesCore` cannot import `MetalNodesRender`, so the default is the literal. Task 11 adds a test asserting `VertexStage.functionName == "mn_fullscreenVertex"` so the two can never drift.

- [ ] **Step 3: Add the target branch**

In `generate(...)`, the effective-target switch gains a case:

```swift
        case .realityKit:
            return try assembleRealityKit(doc, terminal: terminal, viewer: viewer, registry: registry,
                                          functions: functions, groupFunctions: groupFunctions)
```

Note what is *not* passed: `order` and `resolved`. The whole-graph order the caller computed spans both stages at once, which is exactly what this target must not do — the assembler derives its own order per stage and resolves types against each.

Write the assembler:

```swift
    /// The RealityKit target (spec §23.4): two passes over one graph, one shared set of bindings,
    /// two products — a 3D preview program in `source` and two `[[visible]]` functions in
    /// `exportSource`.
    private static func assembleRealityKit(_ doc: ShaderDocument, terminal: NodeID, viewer: SocketRef?,
                                           registry: NodeRegistry,
                                           functions: [GroupID: GroupFunction],
                                           groupFunctions: [GroupFunction]) throws(GenerationError) -> GeneratedShader {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        // See Step 4: `orders` is `var` because a viewer widens the surface stage.
        var orders: [MaterialStage: [NodeID]] = [
            .surface: MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .surface),
            .geometry: MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: .geometry),
        ]
        let lighting: MaterialLightingModel = viewer == nil ? doc.settings.lightingModel : .unlit

        // Types are resolved once per stage and reused by all three passes over that stage.
        // Node ids are unique document-wide, so the two maps cannot disagree where they overlap.
        var types: [NodeID: ResolvedNode] = [:]
        for stage in MaterialStage.allCases {
            let (r, diags) = TypeResolver.resolve(doc.root, path: .root, document: doc,
                                                  registry: registry, order: orders[stage]!)
            if !diags.isEmpty { throw .invalid(diags) }
            types.merge(r) { $1 }
        }

        /// One pass. `env` decides the accessors; `shared` imposes the union bindings.
        func emit(_ stage: MaterialStage, env: EmitEnvironment, shared: Emitter.SharedBindings?) -> Emitter.Output {
            Emitter.emit(order: orders[stage]!, graph: doc.root, path: .root, document: doc, registry: registry,
                         resolved: types, env: env,
                         reserved: viewer == nil ? UniformLayoutBuilder.standardReserved
                                                 : UniformLayoutBuilder.viewerReserved,
                         functions: functions, shared: shared)
        }

        // Round 1: collect requests. Round 2: emit against their union, so both stages name the
        // same uniform fields and the same texture slots (spec §23.4).
        let probeSurface = emit(.surface, env: .realityKitSurface, shared: nil)
        let probeGeometry = emit(.geometry, env: .realityKitGeometry, shared: nil)
        let shared = MaterialCodegen.sharedBindings(
            surface: probeSurface, geometry: probeGeometry,
            reserved: viewer == nil ? UniformLayoutBuilder.standardReserved : UniformLayoutBuilder.viewerReserved)

        let previewSurface = emit(.surface, env: .realityKitSurface, shared: shared)
        let previewGeometry = emit(.geometry, env: .realityKitGeometry, shared: shared)

        // The export reads no uniform buffer: the same environments with a literal speller.
        let baked = EmitEnvironment.bakedUniforms(layout: shared.layout, document: doc, registry: registry)
        func bake(_ env: EmitEnvironment) -> EmitEnvironment {
            EmitEnvironment(uniform: baked, sys: env.sys, textureSample: env.textureSample,
                            textureName: env.textureName, usesLayer: env.usesLayer)
        }
        let exportSurface = emit(.surface, env: bake(.realityKitSurface), shared: shared)
        let exportGeometry = emit(.geometry, env: bake(.realityKitGeometry), shared: shared)

        let preview = MaterialPreviewCodegen.program(
            surface: previewSurface, geometry: previewGeometry, groupFunctions: groupFunctions,
            terminal: terminal, layout: shared.layout, lighting: lighting,
            textures: shared.order, viewerExpression: viewerExpression)
        let export = MaterialCodegen.exportSource(
            surface: exportSurface, geometry: exportGeometry, groupFunctions: groupFunctions,
            terminal: terminal, lighting: doc.settings.lightingModel, exportName: doc.settings.exportName,
            textures: shared.order)   // the export always uses the document's model, never the viewer's

        let names = MaterialCodegen.functionNames(exportName: doc.settings.exportName)
        var stageNames: [MaterialStage: String] = [.surface: names.surface]
        if MaterialCodegen.hasGeometryWork(exportGeometry, terminal: terminal) {
            stageNames[.geometry] = names.geometry
        }

        return GeneratedShader(source: preview.text, layout: shared.layout, lineMap: preview.map,
                               resolved: merged(types, groupFunctions),
                               fragmentFunctionName: fragmentFunctionName, target: .realityKit,
                               viewer: nil, exportSource: export, functionName: name,
                               textures: shared.order, stageFunctionNames: stageNames,
                               vertexFunctionName: MaterialPreviewCodegen.vertexFunctionName)
    }
```

The `lighting` and viewer handling referred to by Step 4 slot into the two `MaterialCodegen`/`MaterialPreviewCodegen` calls above; write Step 4 before running the tests.

- [ ] **Step 4: Keep the viewer honest**

A viewer is a preview concept and is already forced to `.fragment` by the existing line

```swift
        let effectiveTarget: OutputTarget = viewer == nil ? target : .fragment
```

Under `.realityKit` that would generate a *fullscreen* program from a graph that has no Fragment Output, and `terminal` is the Material Output. Change the viewer handling so a viewer under `.realityKit` renders on the mesh as unlit colour, per spec §23.5:

```swift
        // A viewer is a preview concept (spec §19.3): a 2D target previews it through the fragment
        // program, and the 3D target renders it as unlit colour on the mesh (spec §23.5) — a
        // fullscreen program has no terminal to run to under `.realityKit`.
        let effectiveTarget: OutputTarget = viewer == nil || target == .realityKit ? target : .fragment
```

Step 3's assembler already declares `var orders` and the `lighting` override (`viewer == nil ? doc.settings.lightingModel : .unlit`). Three concrete additions complete the picture.

**(a) The surface stage's order must reach the viewed node.** A viewed node need not feed the terminal at all — that is the whole point of the viewer flag. Insert this in `assembleRealityKit` immediately after `orders` is declared:

```swift
        if let v = viewer, doc.root.nodes[v.node] != nil {
            // The viewed node may feed nothing; the surface pass must still compute it.
            var surface = TopoSort.order(doc.root, from: v.node)
            let existing = Set(surface)
            surface += orders[.surface]!.filter { !existing.contains($0) }
            orders[.surface] = surface
        }
```

**(b) One widening rule, shared with the fragment path.** Factor the expression out of `ViewerWrap.statement` so both callers use it. In `MetalNodesCore/Codegen/ViewerWrap.swift`:

```swift
public enum ViewerWrap {
    /// The `float4` a viewed socket of `type` displays as (spec §9.3, §19.3). `float`/`int`
    /// normalise through the manual range; vectors widen; `bool` is on or off.
    public static func expression(variable v: String, type: SocketType) -> String? {
        switch type {
        case .float: "float4(float3(saturate((\(v) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0)"
        case .int: "float4(float3(saturate((float(\(v)) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0)"
        case .float2: "float4(\(v), 0.0, 1.0)"
        case .float3: "float4(\(v), 1.0)"
        case .float4, .color: v
        case .bool: "float4(float3(\(v) ? 1.0 : 0.0), 1.0)"
        case .texture: nil
        }
    }

    /// The last statement of a viewer fragment program.
    public static func statement(variable v: String, type: SocketType) -> String? {
        expression(variable: v, type: type).map { "return \($0);" }
    }
}
```

`ViewerCodegenTests` is the regression gate on this refactor: the fragment path's golden statements must not change by one character.

**(c) The viewed value becomes the emissive term.** Give `MaterialPreviewCodegen.fragmentBody` (and `program`) an extra parameter:

```swift
    static func fragmentBody(surface: Emitter.Output, terminal: NodeID,
                             lighting: MaterialLightingModel,
                             viewerExpression: String? = nil) -> [(line: String, owner: NodeID?)] {
```

and, where it writes the emissive line:

```swift
        add("    float4 emissive = \(viewerExpression ?? value("emissive", "float4(0.0, 0.0, 0.0, 1.0)"));", terminal)
```

In `assembleRealityKit`, build it after `previewSurface` is emitted:

```swift
        let viewerExpression: String? = viewer.flatMap { v in
            guard let variable = previewSurface.outputVars[v],
                  let type = types[v.node]?.outputTypes[v.socket] else { return nil }
            return ViewerWrap.expression(variable: variable, type: type)
        }
```

and pass it into `MaterialPreviewCodegen.program`, which forwards it to `fragmentBody`. With `lighting` forced to `.unlit`, the fragment stage returns `float4(emissive.rgb, opacity)` — the viewed value, flat on the mesh, exactly as spec §23.5 asks.

- [ ] **Step 5: Run the two gate suites**

Run: `swift test --package-path MetalNodesKit --filter MaterialExportSourceTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialPreviewCodegenTests`
Expected: PASS.

- [ ] **Step 6: Add the viewer test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialPreviewCodegenTests.swift`:

```swift
@Suite struct MaterialViewerTests {
    @Test func aViewedSocketRendersAsUnlitColourOnTheMesh() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let noise = NodeInstance(id: NodeID(), kind: .builtin("noise.value"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[noise.id] = noise
        doc.root = g

        let out = NodeRegistry.builtin["noise.value"]!.outputs.first!.name
        let shader = try ShaderGenerator.generate(doc, target: .realityKit, viewer: SocketRef(noise.id, out))
        #expect(shader.target == .realityKit)
        #expect(shader.viewer != nil)
        // Unlit: the GGX helpers are not emitted, and the mesh vertex stage still is.
        #expect(!shader.source.contains("mn_ggx_distribution"))
        #expect(shader.source.contains("vertex VertexOut mn_meshVertex("))
        // The viewer range fields exist, as they do for the 2D viewer path.
        #expect(shader.layout.hasReserved("viewerMin"))
    }
}
```

- [ ] **Step 7: Run the whole suite**

Run: `swift test --package-path MetalNodesKit`
Expected: PASS — every material test green, every 2D golden unchanged.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesCore MetalNodesKit/Tests/MetalNodesCoreTests
git commit -m "feat(core): generate the RealityKit target — export and 3D preview

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 10: Meshes and the orbit camera

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/PreviewMesh.swift` — `PreviewMesh` and `OrbitCamera`
- Create: `MetalNodesKit/Sources/MetalNodesRender/MeshVertex.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/MeshBuilder.swift`
- Create: `MetalNodesKit/Sources/MetalNodesRender/CameraUniforms.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/MeshBuilderTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/CameraUniformsTests.swift`

**Where each type lives:** `PreviewMesh` and `OrbitCamera` are *view state* — Task 14 stores them in `EditorViewState`, which lives in `MetalNodesCore`, and Core cannot import Render. So those two go in Core from the start. `MeshVertex`, `CameraUniforms`, `MeshBuilder` and `OrbitCamera.uniforms(aspect:)` stay in Render, which imports Core.

**Interfaces:**
- Consumes: `MaterialPreviewCodegen.meshVertexStruct` / `.cameraStruct` (Task 8) — only as the text the layouts must match.
- Produces:
  - `PreviewMesh: String, Codable, Sendable, CaseIterable, Hashable { case sphere, cube, plane, torus }` with `title: String`.
  - `MeshVertex` (`position`, `normal`, `tangent: SIMD4<Float>`, `uv`, `color`).
  - `MeshBuilder.build(_ mesh: PreviewMesh) -> (vertices: [MeshVertex], indices: [UInt16])`.
  - `OrbitCamera: Codable, Sendable, Hashable { var azimuth, elevation, distance: Float }` with `.default`, `orbit(dx:dy:)`, `dolly(_:)`, and `uniforms(aspect:) -> CameraUniforms`.
  - `CameraUniforms` matching `MaterialPreviewCodegen.cameraStruct`.

Everything here is pure CPU arithmetic — no `MTLDevice`, so the tests run anywhere.

- [ ] **Step 1: Write the failing tests**

Create `MetalNodesKit/Tests/MetalNodesRenderTests/MeshBuilderTests.swift`:

```swift
import Testing
import simd
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct MeshBuilderTests {
    @Test(arguments: PreviewMesh.allCases)
    func everyMeshIsNonEmptyAndWellIndexed(_ mesh: PreviewMesh) {
        let (vertices, indices) = MeshBuilder.build(mesh)
        #expect(vertices.count >= 4, "\(mesh)")
        #expect(indices.count % 3 == 0, "\(mesh)")
        #expect(!indices.isEmpty, "\(mesh)")
        for i in indices { #expect(Int(i) < vertices.count, "\(mesh) index \(i)") }
    }

    @Test(arguments: PreviewMesh.allCases)
    func normalsAreUnitLength(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(abs(simd_length(v.normal) - 1) < 1e-3, "\(mesh)")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func tangentsAreUnitLengthAndPerpendicularToNormals(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(abs(simd_length(v.tangent.xyz) - 1) < 1e-3, "\(mesh)")
            #expect(abs(simd_dot(v.tangent.xyz, v.normal)) < 1e-3, "\(mesh)")
            #expect(abs(abs(v.tangent.w) - 1) < 1e-6, "\(mesh) handedness")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func uvsStayInsideTheUnitSquare(_ mesh: PreviewMesh) {
        for v in MeshBuilder.build(mesh).vertices {
            #expect(v.uv.x >= -1e-4 && v.uv.x <= 1 + 1e-4, "\(mesh)")
            #expect(v.uv.y >= -1e-4 && v.uv.y <= 1 + 1e-4, "\(mesh)")
        }
    }

    @Test(arguments: PreviewMesh.allCases)
    func everyMeshFitsTheUnitBall(_ mesh: PreviewMesh) {
        // The camera's default distance assumes a roughly unit-radius model.
        for v in MeshBuilder.build(mesh).vertices {
            #expect(simd_length(v.position) <= 1.75, "\(mesh)")
        }
    }

    @Test func buildingIsDeterministic() {
        let a = MeshBuilder.build(.sphere), b = MeshBuilder.build(.sphere)
        #expect(a.vertices == b.vertices)
        #expect(a.indices == b.indices)
    }

    /// The Swift struct and the MSL struct must agree, or the vertex stage reads garbage.
    @Test func theSwiftLayoutMatchesTheGeneratedMslStruct() {
        #expect(MemoryLayout<MeshVertex>.stride == 64)   // 12 + 12 + 16 + 8 + 16, padded to 16
        #expect(MaterialPreviewCodegen.meshVertexStruct.contains("float3 position;"))
        #expect(MaterialPreviewCodegen.meshVertexStruct.contains("float4 tangent;"))
    }
}
```

If `MemoryLayout<MeshVertex>.stride` is not 64 once written, do **not** change the assertion to whatever it happens to be — pad the Swift struct explicitly so the MSL struct's natural layout matches, and record the chosen padding in a comment. MSL aligns `float3` to 16 bytes; Swift's `SIMD3<Float>` does too, which is why the sizes agree, but assert it rather than assume it.

Create `MetalNodesKit/Tests/MetalNodesRenderTests/CameraUniformsTests.swift`:

```swift
import Testing
import simd
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct CameraUniformsTests {
    @Test func theDefaultCameraLooksAtTheOrigin() {
        let c = OrbitCamera.default
        let u = c.uniforms(aspect: 1)
        // Eye is `distance` from the origin.
        #expect(abs(simd_length(u.cameraPosition) - c.distance) < 1e-4)
        // The origin projects near the centre of clip space.
        let clip = u.viewToProjection * (u.worldToView * SIMD4<Float>(0, 0, 0, 1))
        #expect(abs(clip.x) < 1e-4)
        #expect(abs(clip.y) < 1e-4)
        #expect(clip.w > 0)
    }

    @Test func orbitingWrapsAzimuthAndClampsElevation() {
        var c = OrbitCamera.default
        c.orbit(dx: 100, dy: 100)
        #expect(c.elevation <= Float.pi / 2 - 0.01)
        c.orbit(dx: 0, dy: -1000)
        #expect(c.elevation >= -Float.pi / 2 + 0.01)
    }

    @Test func dollyingStaysPositiveAndBounded() {
        var c = OrbitCamera.default
        c.dolly(-1000)
        #expect(c.distance >= 0.5)
        c.dolly(1000)
        #expect(c.distance <= 20)
    }

    @Test func normalToWorldIsTheInverseTransposeOfTheUpperLeft() {
        let u = OrbitCamera.default.uniforms(aspect: 1.7)
        // With an identity model transform the normal matrix is identity too.
        let n = u.normalToWorld
        #expect(abs(n.columns.0.x - 1) < 1e-5)
        #expect(abs(n.columns.1.y - 1) < 1e-5)
        #expect(abs(n.columns.2.z - 1) < 1e-5)
    }

    @Test func aspectWidensTheHorizontalFieldOfView() {
        let square = OrbitCamera.default.uniforms(aspect: 1)
        let wide = OrbitCamera.default.uniforms(aspect: 2)
        #expect(wide.viewToProjection.columns.0.x < square.viewToProjection.columns.0.x)
        #expect(abs(wide.viewToProjection.columns.1.y - square.viewToProjection.columns.1.y) < 1e-5)
    }

    @Test func theSwiftLayoutMatchesTheGeneratedMslStruct() {
        // float4x4 ×3 (192) + float3x3 (48) + float3 (16) = 256.
        #expect(MemoryLayout<CameraUniforms>.stride == 256)
        #expect(MaterialPreviewCodegen.cameraStruct.contains("float3x3 normalToWorld;"))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path MetalNodesKit --filter MeshBuilderTests`
Expected: FAIL — no `MeshBuilder`.

- [ ] **Step 3: Write the vertex and mesh types**

Create `MetalNodesKit/Sources/MetalNodesCore/PreviewMesh.swift`:

```swift
import Foundation

/// Which shape the 3D preview draws (spec §23.5). View state, not document state — it lives in
/// Core because `EditorViewState` stores it and Core cannot import Render.
public enum PreviewMesh: String, Codable, Sendable, CaseIterable, Hashable {
    case sphere, cube, plane, torus

    public var title: String {
        switch self {
        case .sphere: "Sphere"
        case .cube: "Cube"
        case .plane: "Plane"
        case .torus: "Torus"
        }
    }
}

/// The 3D preview's camera: an angle pair and a distance, orbiting the origin (spec §23.5).
/// View state — persisted with the document, never undone. The matrices it produces live in
/// `MetalNodesRender`, because `CameraUniforms` is a GPU layout.
public struct OrbitCamera: Codable, Sendable, Hashable {
    public var azimuth: Float
    public var elevation: Float
    public var distance: Float

    public static let `default` = OrbitCamera(azimuth: 0.6, elevation: 0.3, distance: 3.0)

    public init(azimuth: Float = 0.6, elevation: Float = 0.3, distance: Float = 3.0) {
        self.azimuth = azimuth; self.elevation = elevation; self.distance = distance
    }

    /// A drag in points. Elevation clamps just short of the poles so the up vector never degenerates.
    public mutating func orbit(dx: Float, dy: Float) {
        azimuth += dx * 0.01
        elevation = min(max(elevation + dy * 0.01, -.pi / 2 + 0.01), .pi / 2 - 0.01)
    }

    /// Scroll or pinch. Bounded so the model can neither be lost nor turned inside out.
    public mutating func dolly(_ delta: Float) {
        distance = min(max(distance - delta * 0.01, 0.5), 20)
    }
}
```

Create `MetalNodesKit/Sources/MetalNodesRender/MeshVertex.swift`:

```swift
import Foundation
import simd

/// One preview mesh vertex. The field order and padding match
/// `MaterialPreviewCodegen.meshVertexStruct`; `MeshBuilderTests` asserts the stride.
///
/// `tangent.w` carries handedness: the bitangent is `cross(normal, tangent.xyz) * tangent.w`.
public struct MeshVertex: Equatable, Sendable {
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var tangent: SIMD4<Float>
    public var uv: SIMD2<Float>
    public var color: SIMD4<Float>

    public init(position: SIMD3<Float>, normal: SIMD3<Float>, tangent: SIMD4<Float>,
                uv: SIMD2<Float>, color: SIMD4<Float> = .init(1, 1, 1, 1)) {
        self.position = position; self.normal = normal; self.tangent = tangent
        self.uv = uv; self.color = color
    }
}
```

- [ ] **Step 4: Write the mesh builder**

Create `MetalNodesKit/Sources/MetalNodesRender/MeshBuilder.swift`:

```swift
import Foundation
import simd

/// Procedural preview meshes (spec §23.5). Pure CPU arithmetic — no Metal — so the geometry is
/// unit-testable without a device.
///
/// UVs use the **bottom-left origin** the fragment target uses, so a graph reads the same in the
/// 2D and the 3D preview.
public enum MeshBuilder {
    public static func build(_ mesh: PreviewMesh) -> (vertices: [MeshVertex], indices: [UInt16]) {
        switch mesh {
        case .sphere: sphere(slices: 48, stacks: 24)
        case .cube: cube()
        case .plane: plane(divisions: 16)
        case .torus: torus(major: 48, minor: 24, majorRadius: 0.7, minorRadius: 0.3)
        }
    }

    private static func sphere(slices: Int, stacks: Int) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...stacks {
            let phi = Float(j) / Float(stacks) * .pi          // 0…π, north to south
            let sinPhi = sin(phi), cosPhi = cos(phi)
            for i in 0...slices {
                let theta = Float(i) / Float(slices) * 2 * .pi
                let sinTheta = sin(theta), cosTheta = cos(theta)
                let n = SIMD3<Float>(sinPhi * cosTheta, cosPhi, sinPhi * sinTheta)
                // ∂p/∂θ, the direction u increases in — perpendicular to the normal by construction.
                let t = SIMD3<Float>(-sinTheta, 0, cosTheta)
                let tangent = simd_length(t) > 1e-4 ? simd_normalize(t) : SIMD3<Float>(1, 0, 0)
                v.append(MeshVertex(position: n, normal: n,
                                    tangent: SIMD4<Float>(tangent, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(slices),
                                                     1 - Float(j) / Float(stacks))))
            }
        }
        return (v, gridIndices(columns: slices, rows: stacks))
    }

    private static func plane(divisions n: Int) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...n {
            for i in 0...n {
                let x = Float(i) / Float(n) * 2 - 1
                let z = Float(j) / Float(n) * 2 - 1
                v.append(MeshVertex(position: SIMD3<Float>(x, 0, z),
                                    normal: SIMD3<Float>(0, 1, 0),
                                    tangent: SIMD4<Float>(1, 0, 0, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(n), 1 - Float(j) / Float(n))))
            }
        }
        return (v, gridIndices(columns: n, rows: n))
    }

    private static func torus(major: Int, minor: Int, majorRadius R: Float, minorRadius r: Float) -> ([MeshVertex], [UInt16]) {
        var v: [MeshVertex] = []
        for j in 0...minor {
            let phi = Float(j) / Float(minor) * 2 * .pi
            let cosPhi = cos(phi), sinPhi = sin(phi)
            for i in 0...major {
                let theta = Float(i) / Float(major) * 2 * .pi
                let cosTheta = cos(theta), sinTheta = sin(theta)
                let p = SIMD3<Float>((R + r * cosPhi) * cosTheta, r * sinPhi, (R + r * cosPhi) * sinTheta)
                let n = simd_normalize(SIMD3<Float>(cosPhi * cosTheta, sinPhi, cosPhi * sinTheta))
                let t = simd_normalize(SIMD3<Float>(-sinTheta, 0, cosTheta))
                v.append(MeshVertex(position: p, normal: n, tangent: SIMD4<Float>(t, 1),
                                    uv: SIMD2<Float>(Float(i) / Float(major), 1 - Float(j) / Float(minor))))
            }
        }
        return (v, gridIndices(columns: major, rows: minor))
    }

    /// Six faces, four vertices each — the seams are real, so normals and UVs stay per-face.
    private static func cube() -> ([MeshVertex], [UInt16]) {
        let faces: [(normal: SIMD3<Float>, tangent: SIMD3<Float>)] = [
            (SIMD3( 0,  0,  1), SIMD3(1, 0, 0)), (SIMD3( 0,  0, -1), SIMD3(-1, 0, 0)),
            (SIMD3( 1,  0,  0), SIMD3(0, 0, -1)), (SIMD3(-1,  0,  0), SIMD3(0, 0, 1)),
            (SIMD3( 0,  1,  0), SIMD3(1, 0, 0)),  (SIMD3( 0, -1,  0), SIMD3(1, 0, 0)),
        ]
        var v: [MeshVertex] = []
        var indices: [UInt16] = []
        for face in faces {
            let bitangent = simd_cross(face.normal, face.tangent)
            let base = UInt16(v.count)
            for (dx, dy) in [(-1, -1), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
                let p = face.normal + face.tangent * dx + bitangent * dy
                v.append(MeshVertex(position: p, normal: face.normal,
                                    tangent: SIMD4<Float>(face.tangent, 1),
                                    uv: SIMD2<Float>((dx + 1) / 2, (dy + 1) / 2)))
            }
            indices += [base, base + 1, base + 2, base, base + 2, base + 3]
        }
        return (v, indices)
    }

    /// Two triangles per cell of a `(columns+1) × (rows+1)` vertex grid, counter-clockwise.
    private static func gridIndices(columns: Int, rows: Int) -> [UInt16] {
        var out: [UInt16] = []
        let stride = columns + 1
        for j in 0..<rows {
            for i in 0..<columns {
                let a = UInt16(j * stride + i), b = a + 1
                let c = UInt16((j + 1) * stride + i), d = c + 1
                out += [a, c, b, b, c, d]
            }
        }
        return out
    }
}
```

The cube's positions run to `±1` on each axis, so its corners are at `√3 ≈ 1.732` — inside the 1.75 bound the test asserts, deliberately.

- [ ] **Step 5: Write the camera**

Create `MetalNodesKit/Sources/MetalNodesRender/CameraUniforms.swift` — the GPU layout and the
matrix arithmetic, as an extension on the Core type:

```swift
import Foundation
import simd
import MetalNodesCore

/// Matches `MaterialPreviewCodegen.cameraStruct` field for field; bound at buffer index 1 in both
/// stages (spec §23.5). Camera data lives in its own buffer so `SocketType` never needs a matrix
/// case and no node can reach it.
public struct CameraUniforms: Equatable, Sendable {
    public var modelToWorld: float4x4
    public var worldToView: float4x4
    public var viewToProjection: float4x4
    public var normalToWorld: float3x3
    public var cameraPosition: SIMD3<Float>
}

public extension OrbitCamera {
    var eye: SIMD3<Float> {
        SIMD3(distance * cos(elevation) * sin(azimuth),
              distance * sin(elevation),
              distance * cos(elevation) * cos(azimuth))
    }

    func uniforms(aspect: Float, fieldOfView: Float = .pi / 4,
                  near: Float = 0.05, far: Float = 100) -> CameraUniforms {
        let model = matrix_identity_float4x4
        let view = OrbitCamera.lookAt(eye: eye, center: .zero, up: SIMD3(0, 1, 0))
        let projection = OrbitCamera.perspective(fovY: fieldOfView, aspect: max(aspect, 0.01), near: near, far: far)
        // Inverse transpose of the model's upper-left 3×3; identity here, but written out so a
        // non-identity model transform stays correct if one is ever introduced.
        let upper = float3x3(model.columns.0.xyz, model.columns.1.xyz, model.columns.2.xyz)
        return CameraUniforms(modelToWorld: model, worldToView: view, viewToProjection: projection,
                              normalToWorld: upper.inverse.transpose, cameraPosition: eye)
    }

    internal static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let f = simd_normalize(center - eye)
        let s = simd_normalize(simd_cross(f, up))
        let u = simd_cross(s, f)
        return float4x4(columns: (SIMD4(s.x, u.x, -f.x, 0),
                                  SIMD4(s.y, u.y, -f.y, 0),
                                  SIMD4(s.z, u.z, -f.z, 0),
                                  SIMD4(-simd_dot(s, eye), -simd_dot(u, eye), simd_dot(f, eye), 1)))
    }

    /// Metal's clip space: z in 0…1, right-handed view space.
    internal static func perspective(fovY: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let y = 1 / tan(fovY * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        return float4x4(columns: (SIMD4(x, 0, 0, 0),
                                  SIMD4(0, y, 0, 0),
                                  SIMD4(0, 0, z, -1),
                                  SIMD4(0, 0, z * near, 0)))
    }
}

extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
```

If `SIMD4.xyz` already exists in this target, drop the extension rather than shadowing it — grep for `var xyz` first.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MeshBuilderTests`
Run: `swift test --package-path MetalNodesKit --filter CameraUniformsTests`
Expected: PASS.

- [ ] **Step 7: Run the whole suite and commit**

Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesRender MetalNodesKit/Tests/MetalNodesRenderTests
git commit -m "feat(render): procedural preview meshes and the orbit camera

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 11: The compiler learns a second pipeline shape

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiler.swift:34-100`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/VertexStage.swift` (no code change; a test asserts the name)
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/MaterialCompileTests.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift` (append)

**Interfaces:**
- Consumes: `GeneratedShader.vertexFunctionName`, `.target` (Task 9); `MaterialPreviewCodegen.vertexFunctionName` (Task 8).
- Produces: `ShaderCompiler` compiles a 3D program by taking the vertex function from the *generated* library and attaching a depth attachment. `CompiledPipeline` gains `depthStencilState: MTLDepthStencilState?`, which the renderer sets before drawing.

Today the compiler holds one `MTLFunction`, compiled from `VertexStage.source` in `init`, and pairs it with every fragment function. A 3D program brings its own vertex function and needs `depthAttachmentPixelFormat`.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesRenderTests/MaterialCompileTests.swift`:

```swift
import Testing
import Metal
@testable import MetalNodesRender
@testable import MetalNodesCore

@Suite struct MaterialCompileTests {
    /// Every 3D program shape must reach a linked pipeline — that is what a preview failing
    /// silently would look like, and no unit test on the source text can catch it.
    @Test(arguments: [PreviewMesh.sphere], [MaterialLightingModel.lit, .unlit], [true, false])
    func everyThreeDimensionalProgramCompiles(_ mesh: PreviewMesh,
                                              _ lighting: MaterialLightingModel,
                                              _ withGeometry: Bool) async throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            withKnownIssue("no Metal device") { Issue.record("skipped") }
            return
        }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(0.2, 0.6, 1, 1))
        g.nodes[terminal.id] = terminal
        g.nodes[color.id] = color
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "emissive")] = SocketRef(color.id, "out")
        if withGeometry {
            let noise = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[noise.id] = noise
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(noise.id, "out")
        }
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let compiler = try ShaderCompiler(device: device)
        let result = await compiler.compile(shader, generation: 1)
        guard case .success(let pipeline) = result else {
            Issue.record("compile failed: \(result)")
            return
        }
        #expect(pipeline.depthStencilState != nil)
    }

    /// A graph reading every 3D input node in its legal stage must still compile — the shims'
    /// accessor names are only right if the compiler agrees.
    @Test func everyThreeDimensionalInputCompiles() async throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        // Surface-legal 3D inputs, each summed into base color through a Vector Length.
        var previous: SocketRef?
        for id in ["input.worldPosition", "input.modelPosition", "input.normal3d",
                   "input.tangent", "input.bitangent", "input.viewDirection"] {
            let n = NodeInstance(id: NodeID(), kind: .builtin(id), position: .zero)
            g.nodes[n.id] = n
            previous = SocketRef(n.id, NodeRegistry.builtin[id]!.outputs.first!.name)
        }
        g.inputs[SocketRef(terminal.id, "baseColor")] = previous
        // Vertex ID is geometry-only.
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        g.nodes[vid.id] = vid
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let compiler = try ShaderCompiler(device: device)
        if case .failure(let message, _, _) = await compiler.compile(shader, generation: 1) {
            Issue.record("compile failed: \(message)")
        }
    }
}
```

Append to `MetalNodesKit/Tests/MetalNodesRenderTests/ShaderCompilerTests.swift`:

```swift
@Suite struct VertexFunctionNameTests {
    /// `MetalNodesCore` cannot import `MetalNodesRender`, so `GeneratedShader.vertexFunctionName`
    /// defaults to the string literal. This is the guard against the two drifting apart.
    @Test func theDefaultVertexFunctionNameMatchesTheStaticStage() {
        #expect(VertexStage.functionName == "mn_fullscreenVertex")
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        let shader = try? ShaderGenerator.generate(doc, target: .fragment)
        #expect(shader?.vertexFunctionName == VertexStage.functionName)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialCompileTests`
Expected: FAIL — `CompiledPipeline` has no `depthStencilState`, and the compiler looks for `mn_fullscreenVertex` in a library that defines `mn_meshVertex`.

- [ ] **Step 3: Teach the compiler both shapes**

In `MetalNodesKit/Sources/MetalNodesRender/ShaderCompiler.swift`:

```swift
public struct CompiledPipeline: @unchecked Sendable {
    public let state: MTLRenderPipelineState
    public let shader: GeneratedShader
    public let generation: UInt64
    /// Depth testing for a 3D program (spec §23.5); `nil` for the fullscreen path, which has no
    /// depth attachment and must not set one.
    public let depthStencilState: MTLDepthStencilState?

    public init(state: MTLRenderPipelineState, shader: GeneratedShader, generation: UInt64,
                depthStencilState: MTLDepthStencilState? = nil) {
        self.state = state; self.shader = shader; self.generation = generation
        self.depthStencilState = depthStencilState
    }
}
```

The cache key gains the depth format, because a pipeline built without a depth attachment cannot be reused with one:

```swift
    private struct CacheKey: Hashable { let source: String; let fastMath: Bool; let depth: Bool }
```

`isCached` and `compile` build the key with `depth: shader.target == .realityKit`.

In `compile`, choose the vertex function and the attachments:

```swift
            let lib = try await device.makeLibrary(source: shader.source, options: options)
            guard let frag = lib.makeFunction(name: shader.fragmentFunctionName) else {
                throw ShaderCompilerError.fragmentFunctionMissing
            }
            // A 3D program brings its own vertex stage — that is what makes a geometry modifier
            // visible in the preview (spec §23.5). Every 2D program uses the static one compiled
            // in `init`.
            let vertex: MTLFunction
            if shader.vertexFunctionName == VertexStage.functionName {
                vertex = vertexFunction
            } else if let generated = lib.makeFunction(name: shader.vertexFunctionName) {
                vertex = generated
            } else {
                throw ShaderCompilerError.vertexFunctionMissing
            }
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = vertex
            desc.fragmentFunction = frag
            desc.colorAttachments[0].pixelFormat = pixelFormat
            let needsDepth = shader.target == .realityKit
            if needsDepth { desc.depthAttachmentPixelFormat = ShaderCompiler.depthPixelFormat }
            let state = try await device.makeRenderPipelineState(descriptor: desc)
            insert(key, state)
            return finish(state, shader, generation)
```

Add the format and the depth state, built once:

```swift
    /// The 3D preview's depth attachment (spec §23.5). `MTKView.depthStencilPixelFormat` must match.
    public static let depthPixelFormat: MTLPixelFormat = .depth32Float

    private lazy var depthState: MTLDepthStencilState? = {
        let d = MTLDepthStencilDescriptor()
        d.depthCompareFunction = .less
        d.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: d)
    }()
```

and have `finish` attach it only for a 3D program:

```swift
    private func finish(_ state: MTLRenderPipelineState, _ shader: GeneratedShader, _ generation: UInt64) -> CompileResult {
        .success(CompiledPipeline(state: state, shader: shader, generation: generation,
                                  depthStencilState: shader.target == .realityKit ? depthState : nil))
    }
```

A `lazy var` inside an `actor` is fine — access is already serialized.

- [ ] **Step 4: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialCompileTests`
Run: `swift test --package-path MetalNodesKit --filter ShaderCompilerTests`
Run: `swift test --package-path MetalNodesKit --filter VertexFunctionNameTests`
Expected: PASS.

If a compile fails, the message names a line of `shader.source` — dump it with a temporary `print(shader.source)` in the test, fix `MaterialPreviewCodegen`, and delete the print. The most likely failure is the `MNGeometry` reference member (Task 8 Step 4); switch it to a pointer if the compiler rejects it.

- [ ] **Step 5: Run the whole suite and commit**

Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesRender/ShaderCompiler.swift MetalNodesKit/Tests/MetalNodesRenderTests
git commit -m "feat(render): compile 3D programs with a generated vertex stage and depth

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 12: The 3D draw path

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesRender/MeshResources.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesRender/PreviewView.swift`
- Test: `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift` (append)

**Interfaces:**
- Consumes: `MeshBuilder`, `OrbitCamera`, `CameraUniforms` (Task 10); `CompiledPipeline.depthStencilState`, `ShaderCompiler.depthPixelFormat` (Task 11).
- Produces: `PreviewState.mesh: PreviewMesh`, `PreviewState.orbit: OrbitCamera`; `MeshResources` (an `MTLBuffer` cache keyed by `PreviewMesh`).

- [ ] **Step 1: Write the failing test**

Append to `MetalNodesKit/Tests/MetalNodesRenderTests/PreviewStateTests.swift`:

```swift
@Suite @MainActor struct PreviewState3DTests {
    @Test func meshAndOrbitHaveDefaults() {
        let s = PreviewState()
        #expect(s.mesh == .sphere)
        #expect(s.orbit == OrbitCamera.default)
    }

    @Test func meshBuffersAreCachedPerMesh() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resources = MeshResources(device: device)
        let a = try #require(resources.buffers(for: .sphere))
        let b = try #require(resources.buffers(for: .sphere))
        #expect(a.vertices === b.vertices)
        #expect(a.indexCount == b.indexCount)
        let c = try #require(resources.buffers(for: .cube))
        #expect(a.vertices !== c.vertices)
        #expect(c.indexCount == 36)   // six faces, two triangles each
    }

    @Test func everyMeshProducesBuffers() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let resources = MeshResources(device: device)
        for mesh in PreviewMesh.allCases {
            let b = try #require(resources.buffers(for: mesh), "\(mesh)")
            #expect(b.indexCount > 0, "\(mesh)")
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter PreviewState3DTests`
Expected: FAIL — no `MeshResources`, no `PreviewState.mesh`.

- [ ] **Step 3: Write the mesh buffer cache**

Create `MetalNodesKit/Sources/MetalNodesRender/MeshResources.swift`:

```swift
import Foundation
import Metal

/// GPU buffers for the preview meshes, built on first use and kept (spec §23.5). Four small
/// meshes; there is nothing to evict.
@MainActor
public final class MeshResources {
    public struct Buffers {
        public let vertices: MTLBuffer
        public let indices: MTLBuffer
        public let indexCount: Int
    }

    private let device: MTLDevice
    private var cache: [PreviewMesh: Buffers] = [:]

    public init(device: MTLDevice) { self.device = device }

    public func buffers(for mesh: PreviewMesh) -> Buffers? {
        if let hit = cache[mesh] { return hit }
        let (vertices, indices) = MeshBuilder.build(mesh)
        guard !vertices.isEmpty, !indices.isEmpty,
              let vb = device.makeBuffer(bytes: vertices,
                                         length: MemoryLayout<MeshVertex>.stride * vertices.count,
                                         options: .storageModeShared),
              let ib = device.makeBuffer(bytes: indices,
                                         length: MemoryLayout<UInt16>.stride * indices.count,
                                         options: .storageModeShared) else { return nil }
        let b = Buffers(vertices: vb, indices: ib, indexCount: indices.count)
        cache[mesh] = b
        return b
    }
}
```

- [ ] **Step 4: Add the state**

In `MetalNodesKit/Sources/MetalNodesRender/PreviewState.swift`, add to `PreviewState`:

```swift
    /// Which mesh the 3D preview draws, and where the camera is (spec §23.5, §23.8). View state:
    /// the editor mirrors these into `EditorViewState`, which is persisted and never undone.
    public var mesh: PreviewMesh = .sphere
    public var orbit: OrbitCamera = .default
```

- [ ] **Step 5: Add the draw path**

In `MetalNodesKit/Sources/MetalNodesRender/ShaderRenderer.swift`, add the resources and split the draw:

```swift
    private lazy var meshes = MeshResources(device: device)
```

In `draw(in:)`, after the uniform buffer is filled and the encoder is made, replace the fixed three-vertex draw with a branch:

```swift
        enc.setRenderPipelineState(program.pipeline.state)
        enc.setFragmentBuffer(buffer, offset: 0, index: 0)
        for (index, texture) in program.textures {
            enc.setFragmentTexture(texture, index: index)
        }

        if program.pipeline.shader.target == .realityKit {
            guard let mesh = meshes.buffers(for: state.mesh) else {
                enc.endEncoding(); inflight.signal(); return
            }
            var camera = state.orbit.uniforms(aspect: Float(view.drawableSize.width / max(view.drawableSize.height, 1)))
            if let depth = program.pipeline.depthStencilState { enc.setDepthStencilState(depth) }
            enc.setCullMode(.back)
            enc.setFrontFacing(.counterClockwise)
            enc.setVertexBuffer(mesh.vertices, offset: 0, index: 0)
            enc.setVertexBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            enc.setVertexBuffer(buffer, offset: 0, index: 2)
            enc.setFragmentBytes(&camera, length: MemoryLayout<CameraUniforms>.stride, index: 1)
            for (index, texture) in program.textures { enc.setVertexTexture(texture, index: index) }
            enc.drawIndexedPrimitives(type: .triangle, indexCount: mesh.indexCount,
                                      indexType: .uint16, indexBuffer: mesh.indices, indexBufferOffset: 0)
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        enc.endEncoding()
```

The `MTKView` must carry a depth attachment or the 3D pipeline cannot be used with its render pass. In `PreviewView.makeView`:

```swift
        v.depthStencilPixelFormat = ShaderCompiler.depthPixelFormat
        v.clearDepth = 1.0
```

Setting a depth format the 2D pipelines do not declare is harmless — a pipeline may ignore an attachment the pass provides; the reverse is what fails.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter PreviewState3DTests`
Run: `swift test --package-path MetalNodesKit --filter MaterialCompileTests`
Expected: PASS.

- [ ] **Step 7: Build the app and look at it**

Run:
```bash
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | tail -5
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```
Expected: BUILD SUCCEEDED. The 3D preview cannot be reached from the UI yet (Task 14 adds the picker), so nothing visual is verifiable in this task — that is expected and is why Task 11's compile tests carry the weight here.

- [ ] **Step 8: Commit**

```bash
git add MetalNodesKit/Sources/MetalNodesRender MetalNodesKit/Tests/MetalNodesRenderTests
git commit -m "feat(render): the 3D draw path — mesh buffers, camera and depth

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 13: Export — the `.metal` header and the Swift snippet

**Files:**
- Create: `MetalNodesKit/Sources/MetalNodesCore/Export/MaterialExport.swift`
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Export/ShaderExport.swift:10-19`
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift`

**Interfaces:**
- Consumes: `GeneratedShader.exportSource` / `.stageFunctionNames` (Task 9); `ParamValues` (Task 4); `MaterialCodegen.functionNames` (Task 6).
- Produces: `MaterialExport.header(for:document:registry:) -> String`, `MaterialExport.swiftSnippet(for:document:registry:) -> String`; `ShaderExport.files(for:)` returns two files under `.realityKit`.

- [ ] **Step 1: Write the failing test**

Create `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift`:

```swift
import Testing
@testable import MetalNodesCore

@Suite struct MaterialExportTests {
    private func document(offset: Bool = true, texture: Bool = false,
                          lighting: MaterialLightingModel = .lit) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "brickMaterial"
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var rough = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        rough.params["value"] = .float(0.35)
        g.nodes[terminal.id] = terminal
        g.nodes[rough.id] = rough
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(rough.id, "out")
        if offset {
            let v = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[v.id] = v
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(v.id, "out")
        }
        if texture {
            let s = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
            g.nodes[s.id] = s
            g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(s.id, "color")
        }
        doc.root = g
        return doc
    }

    private func files(_ doc: ShaderDocument) throws -> [ExportFile] {
        try ShaderExport.files(for: doc)
    }

    @Test func twoFilesAreWrittenWithTheExportName() throws {
        let f = try files(document())
        #expect(f.map(\.name).sorted() == ["brickMaterial.metal", "brickMaterial.swift"])
    }

    @Test func theHeaderDocumentsTargetLightingAndBakedParameters() throws {
        let metal = try #require(files(document()).first { $0.name.hasSuffix(".metal") })
        #expect(metal.contents.contains("RealityKit CustomMaterial"))
        #expect(metal.contents.contains("Lighting model: lit"))
        #expect(metal.contents.contains("0.35"))
        #expect(metal.contents.contains("Float · Value") || metal.contents.contains("Float"))
        // The header explains that parameters are frozen, because that is surprising.
        #expect(metal.contents.lowercased().contains("baked"))
    }

    @Test func theSnippetBuildsBothShaderObjectsAndTheMaterial() throws {
        let swift = try #require(files(document()).first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("import RealityKit"))
        #expect(swift.contents.contains("CustomMaterial.SurfaceShader(named: \"brickMaterial_surface\""))
        #expect(swift.contents.contains("CustomMaterial.GeometryModifier(named: \"brickMaterial_geometry\""))
        #expect(swift.contents.contains("lightingModel: .lit"))
    }

    /// Apple: a modifier that moves vertices outside the original bounds can get the entity culled.
    @Test func theSnippetMentionsBoundsMarginOnlyWhenThereIsAGeometryModifier() throws {
        let withOffset = try #require(files(document(offset: true)).first { $0.name.hasSuffix(".swift") })
        #expect(withOffset.contents.contains("boundsMargin"))

        let without = try #require(files(document(offset: false)).first { $0.name.hasSuffix(".swift") })
        #expect(!without.contents.contains("boundsMargin"))
        #expect(!without.contents.contains("GeometryModifier"))
    }

    @Test func theSnippetAssignsTheCustomTextureWhenTheGraphSamples() throws {
        let sampled = try #require(files(document(texture: true)).first { $0.name.hasSuffix(".swift") })
        #expect(sampled.contents.contains("custom.texture"))

        let plain = try #require(files(document()).first { $0.name.hasSuffix(".swift") })
        #expect(!plain.contents.contains("custom.texture"))
    }

    @Test func unlitIsCarriedIntoTheSnippet() throws {
        let swift = try #require(files(document(lighting: .unlit)).first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("lightingModel: .unlit"))
    }

    @Test func exportIsDeterministic() throws {
        let doc = document(texture: true)
        #expect(try files(doc) == (try files(doc)))
    }

    /// The other targets must be untouched by the new branch.
    @Test func fragmentAndStitchableExportsAreUnchanged() throws {
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        #expect(try ShaderExport.files(for: doc).map(\.name) == ["metalNodesShader.metal"])
        doc.settings.target = .stitchable(.colorEffect)
        #expect(try ShaderExport.files(for: doc).map(\.name).sorted()
                == ["metalNodesShader.metal", "metalNodesShader.swift"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter MaterialExportTests`
Expected: FAIL — `ShaderExport.files` writes only a `.metal` for `.realityKit` (it falls into the non-stitchable branch), with the fragment header.

- [ ] **Step 3: Write the header and snippet**

Create `MetalNodesKit/Sources/MetalNodesCore/Export/MaterialExport.swift`:

```swift
import Foundation

/// What File ▸ Export Shader… writes for the RealityKit target (spec §23.6): a `.metal` holding
/// both `[[visible]]` functions and a `.swift` snippet that builds the material.
public enum MaterialExport {
    /// The comment block prepended to the exported source: what this file is, which lighting model
    /// it was written for, every baked parameter with the node it came from, and the texture slot.
    public static func header(for shader: GeneratedShader, document doc: ShaderDocument,
                              registry: NodeRegistry) -> String {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        var lines = [
            "// RealityKit CustomMaterial \"\(name)\" — generated by MetalNodes.",
            "// Lighting model: \(doc.settings.lightingModel.rawValue)",
            "//",
            "// Parameters are baked as literals: a CustomMaterial exposes one float4 and one",
            "// texture, so there is no uniform buffer to read. Edit the graph and re-export to",
            "// change a value.",
            "//",
            "// Baked parameters:",
        ]
        var any = false
        for f in shader.layout.fields {
            guard let path = f.path else { continue }
            any = true
            let value = ParamValues.value(for: path, in: doc, registry: registry)
                .map { ParamValues.mslLiteral($0, as: f.type) } ?? "0.0"
            lines.append("//   \(label(for: path, document: doc, registry: registry)) = \(value)")
        }
        if !any { lines.append("//   (none)") }
        lines.append("// Textures:")
        if shader.textures.isEmpty {
            lines.append("//   (none)")
        } else {
            for slot in shader.textures {
                let assetName = slot.asset.flatMap { doc.settings.assets[$0]?.name } ?? "unassigned"
                lines.append("//   params.textures().custom()  \u{2190} \(assetName)")
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    /// "Node title · Parameter label" for a slot, the same shape `ShaderExport` uses.
    private static func label(for path: ParamPath, document doc: ShaderDocument, registry: NodeRegistry) -> String {
        guard let nodeID = path.instancePath.first,
              let (node, nodePath) = doc.node(nodeID),
              let shape = doc.shape(of: node, in: nodePath, registry: registry) else { return path.param }
        let label = shape.input(named: path.param)?.label ?? shape.param(named: path.param)?.label ?? path.param
        return "\(node.customTitle ?? shape.title) · \(label)"
    }

    /// The Swift the reader pastes into their app.
    public static func swiftSnippet(for shader: GeneratedShader, document doc: ShaderDocument,
                                    registry: NodeRegistry) -> String {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let names = MaterialCodegen.functionNames(exportName: doc.settings.exportName)
        let hasGeometry = shader.stageFunctionNames[.geometry] != nil
        let hasTexture = !shader.textures.isEmpty

        var s = "// \(name).swift — generated by MetalNodes. Pairs with \(name).metal.\n"
        s += "//\n"
        s += "// Add \(name).metal to the target so its functions land in the default library.\n"
        s += "import RealityKit\n"
        s += "import Metal\n\n"
        s += "enum \(name.prefix(1).uppercased() + name.dropFirst())Material {\n"
        s += "    struct NoMetalDevice: Error {}\n\n"
        s += "    /// Builds the material. Call once and reuse it — compiling shaders is not free.\n"
        s += "    @MainActor\n"
        s += "    static func make() throws -> CustomMaterial {\n"
        s += "        guard let device = MTLCreateSystemDefaultDevice() else {\n"
        s += "            throw NoMetalDevice()\n"
        s += "        }\n"
        s += "        let library = try device.makeDefaultLibrary(bundle: .main)\n"
        s += "        let surface = CustomMaterial.SurfaceShader(named: \"\(names.surface)\", in: library)\n"
        if hasGeometry {
            s += "        let geometry = CustomMaterial.GeometryModifier(named: \"\(names.geometry)\", in: library)\n"
            s += "        var material = try CustomMaterial(surfaceShader: surface,\n"
            s += "                                          geometryModifier: geometry,\n"
            s += "                                          lightingModel: \(doc.settings.lightingModel.swiftCase))\n"
        } else {
            s += "        var material = try CustomMaterial(surfaceShader: surface,\n"
            s += "                                          lightingModel: \(doc.settings.lightingModel.swiftCase))\n"
        }
        if hasTexture {
            s += "\n        // The graph samples one texture. `params.textures().custom()` reads this slot.\n"
            s += "        // let resource = try await TextureResource(named: \"YourImage\")\n"
            s += "        // material.custom.texture = .init(resource)\n"
            s += "        _ = material.custom.texture\n"
        }
        s += "        return material\n"
        s += "    }\n"
        if hasGeometry {
            s += "\n    /// A geometry modifier can push vertices outside the entity's original bounds,\n"
            s += "    /// and RealityKit may then cull the entity. Grow the margin to cover the largest\n"
            s += "    /// displacement your graph produces.\n"
            s += "    @MainActor\n"
            s += "    static func apply(to entity: ModelEntity, boundsMargin: Float = 0.5) throws {\n"
            s += "        entity.model?.materials = [try make()]\n"
            s += "        entity.model?.boundsMargin = boundsMargin\n"
            s += "    }\n"
        } else {
            s += "\n    @MainActor\n"
            s += "    static func apply(to entity: ModelEntity) throws {\n"
            s += "        entity.model?.materials = [try make()]\n"
            s += "    }\n"
        }
        s += "}\n"
        return s
    }
}
```

`NoMetalDevice` is declared by the snippet itself — the generated code must compile in the reader's project with no types it does not define, so emit `s += "    struct NoMetalDevice: Error {}\n\n"` as the enum's first member.

- [ ] **Step 4: Route the export**

In `MetalNodesKit/Sources/MetalNodesCore/Export/ShaderExport.swift`, add the branch before the stitchable guard:

```swift
    public static func files(for doc: ShaderDocument, registry: NodeRegistry = .builtin) throws(GenerationError) -> [ExportFile] {
        let name = StitchableCodegen.sanitizedName(doc.settings.exportName)
        let shader = try ShaderGenerator.generate(doc, target: doc.settings.target, viewer: nil, registry: registry)
        if doc.settings.target == .realityKit, let export = shader.exportSource {
            let header = MaterialExport.header(for: shader, document: doc, registry: registry)
            return [ExportFile(name: "\(name).metal", contents: header + export),
                    ExportFile(name: "\(name).swift",
                               contents: MaterialExport.swiftSnippet(for: shader, document: doc, registry: registry))]
        }
        // From here down the function is exactly what it was: the fragment fallback, then the
        // stitchable pair.
        guard let kind = doc.settings.target.stitchableKind, let export = shader.exportSource else {
            let header = fragmentHeader(for: shader, document: doc, registry: registry)
            return [ExportFile(name: "\(name).metal", contents: header + shader.source)]
        }
        return [ExportFile(name: "\(name).metal", contents: export),
                ExportFile(name: "\(name).swift", contents: swiftSnippet(for: shader, kind: kind, document: doc, registry: registry))]
    }
```

- [ ] **Step 5: Add the gated compile test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift`. Model it on the existing gated export-compile test — find it with `grep -rn "xcrun" MetalNodesKit/Tests` and copy its skip mechanism verbatim rather than inventing one:

```swift
@Suite struct MaterialExportCompilesTests {
    /// The exported `.metal` must compile against the SDK. The RealityKit headers ship in the SDK
    /// even though the running OS does not carry them — which is precisely why the *runtime*
    /// compiler cannot build this file and the preview needs its own program (spec §23.4).
    @Test func theExportedMetalCompilesWithXcrunMetal() throws {
        try requireMetalToolchain()          // the same helper the fragment export test uses
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "compileCheck"
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(1, 0.5, 0.25, 1))
        let offset = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, color, offset] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offset.id, "out")
        doc.root = g

        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        try compileWithXcrunMetal(file.contents)   // the same helper; fails the test on a non-zero exit
    }
}
```

If no such helpers exist, write them in this file: a `requireMetalToolchain()` that throws `XCTSkip`-equivalent (`withKnownIssue` or an early `return` after `Issue.record` — match what the existing gated tests do) when `xcrun --find metal` fails, and a `compileWithXcrunMetal(_:)` that writes the source to a temporary file and runs `xcrun metal -c <file> -o /dev/null`, recording the compiler's stderr on failure.

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path MetalNodesKit --filter MaterialExport`
Expected: PASS. If `xcrun metal -c` reports an error in the generated file, that is a real defect in Task 6's `exportSource` — fix the generator, never the assertion.

- [ ] **Step 7: Run the whole suite and commit**

Run: `swift test --package-path MetalNodesKit`

```bash
git add MetalNodesKit/Sources/MetalNodesCore/Export MetalNodesKit/Tests/MetalNodesCoreTests/MaterialExportTests.swift
git commit -m "feat(core): export the RealityKit material as .metal plus a Swift snippet

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 14: The editor — pickers, view state, and camera drag

**Files:**
- Modify: `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift:23-47`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift:188-215`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift:96-109`
- Modify: `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorModel.swift` (publish mesh/orbit)
- Test: `MetalNodesKit/Tests/MetalNodesCoreTests/EditorViewStateTests.swift` (append)

**Interfaces:**
- Consumes: `PreviewMesh`, `OrbitCamera` — already in `MetalNodesCore` (Task 10), which is why `EditorViewState` can store them.
- Produces: `EditorViewState.previewMesh: PreviewMesh`, `EditorViewState.orbit: OrbitCamera`, `EditorModel.setPreviewMesh(_:)`, `EditorModel.setOrbit(_:)`.

- [ ] **Step 1: Write the failing test**

Append to `MetalNodesKit/Tests/MetalNodesCoreTests/EditorViewStateTests.swift`:

```swift
@Suite struct EditorViewState3DTests {
    @Test func meshAndOrbitDefaultAndRoundTrip() throws {
        var s = EditorViewState()
        #expect(s.previewMesh == .sphere)
        #expect(s.orbit == OrbitCamera.default)
        s.previewMesh = .torus
        s.orbit.distance = 4.2
        let back = try JSONDecoder().decode(EditorViewState.self, from: JSONEncoder().encode(s))
        #expect(back.previewMesh == .torus)
        #expect(back.orbit.distance == 4.2)
    }

    /// Every document that predates M7 must open with the defaults, not fail to decode.
    @Test func viewStateWithoutTheNewFieldsDecodes() throws {
        let json = Data(#"{"showsCode":true}"#.utf8)
        let s = try JSONDecoder().decode(EditorViewState.self, from: json)
        #expect(s.previewMesh == .sphere)
        #expect(s.orbit == OrbitCamera.default)
        #expect(s.showsCode)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path MetalNodesKit --filter EditorViewState3DTests`
Expected: FAIL.

- [ ] **Step 3: Add the fields**

In `MetalNodesKit/Sources/MetalNodesCore/EditorViewState.swift`:

```swift
    /// The 3D preview's mesh and camera (spec §23.8). View state: persisted with the document,
    /// never snapshotted, never undone.
    public var previewMesh: PreviewMesh = .sphere
    public var orbit: OrbitCamera = .default
```

`EditorViewState`'s `Codable` conformance is synthesized, so a document without the keys will *throw*, not default. Give it explicit `init(from:)`/`encode(to:)` with `decodeIfPresent`, the way `DocumentSettings` does — check whether `EditorViewState` already has a custom `init(from:)` (M6 added `canvasMode` and `showsInspector` with defaults, so it very likely does) and add the two fields to it.

- [ ] **Step 4: Add the inspector controls**

In `MetalNodesKit/Sources/MetalNodesUI/Editor/InspectorView.swift`, after the Target picker:

```swift
            if s.target == .realityKit {
                Picker("Lighting", selection: Binding(get: { s.lightingModel },
                                                      set: { m in var n = s; n.lightingModel = m; model.apply(.setSettings(n)) })) {
                    ForEach(MaterialLightingModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Mesh", selection: Binding(get: { model.viewState.previewMesh },
                                                  set: { model.setPreviewMesh($0) })) {
                    ForEach(PreviewMesh.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                Text("The preview approximates RealityKit's lit model with Cook-Torrance GGX. It shows the material's shape, not RealityKit's exact output.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
```

The "Copy Swift snippet" button is currently `.disabled(s.target.stitchableKind == nil)`. The RealityKit target writes a snippet too:

```swift
                Button("Copy Swift snippet") { commitExportName(); _ = model.copySwiftSnippet() }
                    .disabled(s.target.stitchableKind == nil && s.target != .realityKit)
```

and the explanatory caption below gains a `.realityKit` case:

```swift
            if s.target == .realityKit {
                Text("Export writes the .metal file with both [[visible]] functions and a .swift snippet that builds the CustomMaterial. Parameter values are baked in; re-export after changing one.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            } else if s.target.stitchableKind != nil {
                Text("Preview renders the same function through a fragment wrapper. Export writes the .metal file and a .swift extension with the ShaderLibrary call in argument order.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            } else {
                Text("Export writes the .metal file with a header documenting the uniform layout and texture slots.")
                    .font(.caption2).foregroundStyle(DraculaToken.muted.color)
            }
```

`model.setPreviewMesh(_:)` is a new view-state mutation on `EditorModel`, alongside the existing `showsCode` / `showsMinimap` toggles — find one (`grep -n "showsMinimap" EditorModel*.swift`) and follow its shape exactly, including whether it is undoable (it is not: view state is never undone, spec §18.3).

- [ ] **Step 5: Publish mesh and camera to the renderer**

In `EditorModel`, wherever `preview` is updated from view state, mirror the two fields:

```swift
        preview.mesh = viewState.previewMesh
        preview.orbit = viewState.orbit
```

Do this in the same place `preview.viewerRange` is published, so one code path owns the editor→renderer mirror.

- [ ] **Step 6: Orbit the camera with the preview drag**

In `MetalNodesKit/Sources/MetalNodesUI/Editor/EditorView.swift`, the preview overlay's `DragGesture` writes `setMouse`. Under `.realityKit` it must orbit instead:

```swift
                        .gesture(DragGesture(minimumDistance: 0)
                            .onChanged { g in
                                if model.document.settings.target == .realityKit {
                                    orbit(g)
                                } else {
                                    setMouse(g.location, in: geo.size)
                                }
                            }
                            .onEnded { _ in lastOrbitTranslation = .zero })
```

with, in the view:

```swift
    @State private var lastOrbitTranslation: CGSize = .zero

    /// Orbits the 3D preview. `DragGesture` reports cumulative translation, so the delta is the
    /// difference from the last event — the same shape the canvas's pan uses.
    private func orbit(_ g: DragGesture.Value) {
        let dx = Float(g.translation.width - lastOrbitTranslation.width)
        let dy = Float(g.translation.height - lastOrbitTranslation.height)
        lastOrbitTranslation = g.translation
        var camera = model.viewState.orbit
        camera.orbit(dx: dx, dy: dy)
        model.setOrbit(camera)
    }
```

`onContinuousHover`'s `setMouse` stays for the 2D targets and must be skipped under `.realityKit` for the same reason:

```swift
                            .onContinuousHover { phase in
                                guard model.document.settings.target != .realityKit else { return }
                                if case .active(let p) = phase { setMouse(p, in: geo.size) }
                            }
```

`model.setOrbit(_:)` is the second new view-state mutation, same shape as `setPreviewMesh`.

- [ ] **Step 7: Run the tests and build**

Run: `swift test --package-path MetalNodesKit`
Run:
```bash
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | tail -5
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```
Expected: tests PASS, BUILD SUCCEEDED.

- [ ] **Step 8: Look at it**

Launch the app, add a Material Output node, switch Target to "RealityKit Material", and confirm: a lit sphere appears; dragging on the preview orbits it; the Mesh picker changes the shape; wiring a colour into Base Color changes the sphere's colour; switching Lighting to Unlit flattens it.

If nothing renders, the first thing to check is the `MTKView` depth attachment (Task 12 Step 5) and then the vertex buffer index — a mismatched buffer index draws nothing and reports no error.

- [ ] **Step 9: Commit**

```bash
git add MetalNodesKit
git commit -m "feat(ui): lighting and mesh pickers, camera orbit under the material target

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

---

### Task 15: Integration — the in-app checklist and the record

**Files:**
- Modify: `README.md` (roadmap row)
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md` (append §14)
- Modify: `docs/superpowers/specs/2026-09-04-metalnodes-design.md` (append §23.10 amendments, if any)
- Modify: `MetalNodesKit/Sources/MetalNodesCore/Library/SampleDocuments.swift` — a RealityKit starter

**Interfaces:**
- Consumes: everything.
- Produces: a verified milestone.

This task is run by the controller, not delegated: it needs the app on screen.

- [ ] **Step 1: Add a RealityKit starter document**

In `MetalNodesKit/Sources/MetalNodesCore/Library/SampleDocuments.swift`, add a `realityKitMaterial` starter beside the existing ones: a Material Output with Value Noise → Roughness, a Color → Base Color, and Time → a small Position Offset through Vector 3, `settings.target = .realityKit`, `lightingModel = .lit`. Follow the file's existing construction style exactly. Add it to whatever list the palette / File ▸ New reads, and extend the starter-document test (`grep -rn "StarterDocuments" MetalNodesKit/Tests`) so the new document is asserted to validate and generate under its own target.

Run: `swift test --package-path MetalNodesKit`
Expected: PASS.

- [ ] **Step 2: Run the full verification**

```bash
swift test --package-path MetalNodesKit 2>&1 | tail -20
swift build --package-path MetalNodesKit 2>&1 | grep -i warning
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | tail -3
git checkout -- MetalNodes.xcodeproj/project.pbxproj
xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build 2>&1 | tail -3
git checkout -- MetalNodes.xcodeproj/project.pbxproj
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project MetalNodes.xcodeproj -scheme MetalNodes -destination 'platform=macOS' build 2>&1 | tail -3
git checkout -- MetalNodes.xcodeproj/project.pbxproj
```

Expected: tests pass, no warnings, three builds succeed. The third is the Xcode 26.6 gate that caught an IRGen crash in M5; do not skip it.

- [ ] **Step 3: Run the in-app checklist**

Launch the app on macOS and work through these, recording pass/fail for each in the ledger:

1. New document → Material Output is absent → switching Target to "RealityKit Material" shows "A RealityKit material needs a Material Output node".
2. Add a Material Output → the sphere appears, lit, grey.
3. Wire a Color into Base Color → the sphere takes the colour.
4. Scrub Roughness through a Float node → the highlight tightens and spreads; no recompile (the generation label does not advance).
5. Wire a Value Noise into Roughness → recompiles once, and the surface varies.
6. Wire Metallic to 1 → the sphere reads as metal, not as plastic.
7. Wire a Vector 3 into Position Offset → the sphere visibly deforms; changing the vector moves it live.
8. Drag on the preview → the camera orbits. Scroll → it dollies. Release and re-drag → no jump.
9. Mesh picker → Cube, Plane, Torus each draw correctly, with no z-fighting and no inside-out faces.
10. Set the viewer flag (◉) on a socket → the mesh shows that value as flat colour, unlit.
11. Clear the viewer → the lit material returns.
12. Lighting → Unlit → only Emissive renders; a wired Base Color produces the "Unlit materials render only Emissive" warning, and the node is not error-outlined (it is a warning).
13. Add a Mouse node and wire it → "Mouse needs the Fragment or SwiftUI target", error-outlined.
14. Add a Vertex ID node and wire it into Roughness → "Vertex ID is not available in the surface stage".
15. Rewire that Vertex ID into Position Offset → the error clears.
16. Add two Texture Sample nodes → the second is refused with "one texture slot".
17. Switch Target back to Fragment with a 3D input node in the graph → "needs the RealityKit Material target"; switching back clears it. Neither terminal node was deleted.
18. Export… → two files written; open the `.metal` and confirm both functions and the baked parameter comment; open the `.swift` and confirm the `boundsMargin` note is present (Position Offset is wired).
19. Copy Swift snippet → the clipboard holds the `.swift` contents.
20. Undo/redo across a target change, a lighting change and a wire → the document returns to each prior state; the mesh choice and camera do **not** move (they are view state).
21. Save, close, reopen → target, lighting model, mesh and camera all restored.
22. Open an M6-era `.mnshader` → it opens as a Fragment document with no diagnostics.

Then the regression subset: M6 checklist items 1–5 on the iPad simulator, and M5 items 1–5 on macOS.

- [ ] **Step 4: Fix what the checklist found**

Each failure gets its own commit, named `fix(<area>): <what> — checklist item N`. Do not batch unrelated fixes.

- [ ] **Step 5: Write the record**

Append §14 to `docs/superpowers/specs/2026-09-04-metalnodes-handoff.md`, in the shape of §13: what was built, the rulings taken during execution with their reasons, the deferred minors, what is owed to a human, and the M8 recommendations (starting with the M6 debt list this milestone deliberately did not take, and `custom_parameter()` mapping for live parameters).

Append §23.10 "M7 amendments" to the design spec listing every place the implementation had to differ from §23 — in particular whichever way `geometry().normal()`'s coordinate space turned out (spec §23.3 records it as unverified; the checklist's item on Normal → Base Color settles it).

Update `README.md`'s roadmap row for M7 to "done" and add the RealityKit target to the Features list.

- [ ] **Step 6: Update memory**

Update `~/.claude/projects/-Users-maxburger-Developer-MetalNodes/memory/metalnodes-project-state.md` with the M7 record — branch, commit count, test counts, rulings location, what is owed — and refresh its `description` line. Add any RealityKit fact that cost real time to discover (the header-availability split, the `half`/`float3` setter asymmetry, whatever the normal-space check settled) so the next session does not re-discover it.

- [ ] **Step 7: Commit and finish**

```bash
git add -A
git commit -m "docs: M7 record — RealityKit material target

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01RPcmDZb2TAGiC8ZmdZtCEF"
```

Then run the whole-branch review (`superpowers:requesting-code-review`, most capable model, the full diff against `main`), apply one fix wave, re-review the fixes, and finish with `superpowers:finishing-a-development-branch`.

---

## What M8 starts from

- **The M6 debt list** (handoff §13), deliberately excluded here: `Document` protocol adoption once Xcode Cloud runs Xcode 27, a plain three-column iPad layout, a generation token in `PickerPresenter`, and the manual checks still owed to a human (macOS Finder→canvas drop, palette drag-in, iPad hardware-keyboard check 14, two-finger pan/pinch, Slide Over compact width).
- **Live material parameters**: map up to four exposed floats onto `params.uniforms().custom_parameter()` so an exported material animates from Swift without re-export (spec §23.6 records this as the natural follow-up).
- **Clearcoat**: three more sockets and the `.clearcoat` lighting model, which M7 left out rather than half-build (spec §23.2).
- **Custom attribute**: `set_custom_attribute` / `custom_attribute()` is the one channel from the geometry stage to the surface stage, and would let a graph pass a computed value across stages instead of recomputing it.
- The two milestones the user already sequenced: **custom code / expression nodes** (M8 candidate) and a **cross-document node library** (M9).
