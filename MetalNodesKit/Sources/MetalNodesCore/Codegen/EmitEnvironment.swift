import Foundation

/// How generated statements spell a uniform read and the four system values (spec §19.2).
/// One emitter serves every target; only this differs.
public struct EmitEnvironment: Sendable {
    /// One system value's spelling in this environment, and whether a node may *read* it.
    /// A fill-only value exists so group-function argument lists compile (§23.4) but is not
    /// something a node can name — that is how Mouse and Resolution stay refused under the
    /// RealityKit target while `mn_g_…(uv, time, size, mouse, …)` still type-checks.
    public struct SysValue: Sendable, Hashable {
        public let spelling: String
        public let readable: Bool
        public init(_ spelling: String, readable: Bool = true) {
            self.spelling = spelling
            self.readable = readable
        }
    }

    public var uniform: @Sendable (UniformField) -> String
    public var sys: [String: SysValue]
    /// The whole sample expression a Texture Sample body becomes, given its slot and the
    /// expression for its `uv` input (spec §21.2). The y flip lives here, not in the loader.
    public var textureSample: @Sendable (TextureSlot, _ uvExpr: String) -> String
    /// How a *call site* in this program spells a slot it passes to a group function.
    public var textureName: @Sendable (TextureSlot) -> String
    /// True in the two environments that sample a SwiftUI `Layer` instead of a bound texture.
    public var usesLayer: Bool
    /// Accessor chains this environment's own generated program reads, beyond what `sys` can
    /// carry (spec §24.5) — currently just `params.textures().custom()`, which `MaterialCodegen`
    /// hoists into a per-slot local wherever a RealityKit material samples a texture (spec §23.6).
    /// `sys` has no key for it: the accessor is the same text for every texture slot, not one
    /// system value. Kept on the environment — the vocabulary's single authority — rather than
    /// left a magic string only `MaterialCodegen` knows, so `canEmit(mslText:)` recognises the
    /// generator's own output as legal.
    public var knownAccessors: Set<String>

    /// Registry-validation vocabulary only — not every environment's `sys` dictionary supplies every
    /// name (the RealityKit builtins are wired by Task 5). Keeps typos in a node body's `{sys.…}`
    /// placeholder from silently producing a comment marker instead of a diagnostic.
    public static let sysNames: Set<String> = ["uv", "time", "resolution", "mouse", "worldPosition",
                                                "modelPosition", "normal3d", "tangent", "bitangent",
                                                "viewDirection", "uv1", "vertexColor", "vertexID",
                                                "screenPosition", "customAttribute"]

    /// A slot sampled by name, y-flipped: the shape every target but the Layer Effect export uses.
    public static func flippedSample(_ name: String, _ uv: String) -> String {
        "\(name).sample(mn_sampler, float2(\(uv).x, 1.0 - \(uv).y))"
    }

    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: SysValue],
                textureSample: @escaping @Sendable (TextureSlot, String) -> String
                    = { slot, uv in EmitEnvironment.flippedSample(slot.fragmentName, uv) },
                textureName: @escaping @Sendable (TextureSlot) -> String = { $0.fragmentName },
                usesLayer: Bool = false, knownAccessors: Set<String> = []) {
        self.uniform = uniform
        self.sys = sys
        self.textureSample = textureSample
        self.textureName = textureName
        self.usesLayer = usesLayer
        self.knownAccessors = knownAccessors
    }

    /// This environment with only its uniform speller replaced: every other field — `sys`,
    /// texture spelling, `usesLayer`, `knownAccessors` — carried through. `ShaderGenerator`'s
    /// export path used to rebuild the environment by hand and silently dropped
    /// `knownAccessors` (handoff T11); a copy that names no field cannot lose one.
    public func withUniformSpeller(_ uniform: @escaping @Sendable (UniformField) -> String) -> EmitEnvironment {
        var copy = self
        copy.uniform = uniform
        return copy
    }

    /// The fragment program (and every viewer program): a `constant Uniforms &u` buffer.
    public static let fragment = EmitEnvironment(
        uniform: { f in f.type == .bool ? "bool(u.\(f.name))" : "u.\(f.name)" },
        sys: ["uv": SysValue("in.uv"), "time": SysValue("u.time"),
              "resolution": SysValue("u.resolution"), "mouse": SysValue("u.mouse")])

    /// Inside a group function (spec §20.4): uniforms are parameters named after their slot's
    /// path, so the function is the same whatever the caller's target.
    public static let groupFunction = EmitEnvironment(
        uniform: { f in
            guard let p = f.path else { return f.name }
            return GroupCodegen.parameterName(for: p)
        },
        sys: ["uv": SysValue("uv"), "time": SysValue("time"),
              "resolution": SysValue("size"), "mouse": SysValue("mouse")],
        textureSample: { slot, uv in flippedSample(slot.parameterName, uv) },
        textureName: { $0.parameterName })

    /// Inside a group function's **layer variant** (spec §22.7): the definition takes no texture
    /// parameter at all — every Texture Sample reads the `SwiftUI::Layer` the caller passes down,
    /// at the caller's `position`, exactly as the exported root function does.
    public static let groupFunctionLayer = EmitEnvironment(
        uniform: groupFunction.uniform,
        sys: groupFunction.sys,
        textureSample: { _, _ in "float4(layer.sample(position))" },
        textureName: { _ in "layer" },
        usesLayer: true)

    /// Inside a stitchable function: uniforms are arguments named after their slots; SwiftUI has
    /// no int/bool `Shader.Argument`, so those arrive as `float` and are cast on read, and
    /// `.color(_:)` arrives as a premultiplied `half4` that is widened to `float4`.
    public static let stitchableFunction = EmitEnvironment(
        uniform: { f in
            switch f.type {
            case .bool: "bool(\(f.name))"
            case .int: "int(\(f.name))"
            case .color: "float4(\(f.name))"
            default: f.name
            }
        },
        sys: ["uv": SysValue("uv"), "time": SysValue("time"),
              "resolution": SysValue("size"), "mouse": SysValue("mouse")])

    /// The exported Layer Effect function (spec §21.2): there is no asset to bind, so every
    /// Texture Sample reads the layer SwiftUI hands the effect. Alpha comes from the layer too.
    /// `Layer::sample` yields a `half4` and MSL widens neither vectors nor their element type
    /// implicitly, so the sample is spelled with the conversion the surrounding `float4` needs.
    public static let layerExport = EmitEnvironment(
        uniform: stitchableFunction.uniform,
        sys: stitchableFunction.sys,
        textureSample: { _, _ in "float4(layer.sample(position))" },
        textureName: { _ in "layer" },
        usesLayer: true)

    /// How each system value is spelled inside a RealityKit function (spec §23.3).
    ///
    /// `resolution` and `mouse` resolve to neutral literals, and both are `readable: false`. The
    /// reason they must exist at all is the **call site**, not any node: every group function's
    /// signature starts `(float2 uv, float time, float2 size, float2 mouse, …)`, and `Emitter`
    /// spells that argument list from these very keys (`Emitter.swift`, the `.group` case), so a
    /// RealityKit material calling a group would otherwise have nothing to pass. `readable: false`
    /// is what keeps that plumbing from becoming a value a node can read.
    ///
    /// (M7 also justified them by the UV node's `aspect` variant, which reads `{sys.resolution}`
    /// and was said to "degenerate to centred UV rather than to nonsense". M8 reversed that: a
    /// degenerate value is a silently wrong one, and §24.10 records the reversal. Bodies that read
    /// these names are now refused under this target — including that variant.)
    public static func materialSys(for stage: MaterialStage) -> [String: SysValue] {
        let geo = stage == .surface ? materialGeometryAccessor : "geo"
        var s: [String: SysValue] = [
            "time": SysValue("params.uniforms().time()"),
            "resolution": SysValue("float2(1.0, 1.0)", readable: false),
            "mouse": SysValue("float2(0.0, 0.0)", readable: false),
            "uv": SysValue("\(geo).uv0()"),
            "uv1": SysValue("\(geo).uv1()"),
            "worldPosition": SysValue("\(geo).world_position()"),
            "modelPosition": SysValue("\(geo).model_position()"),
            "normal3d": SysValue("\(geo).normal()"),
            "bitangent": SysValue("\(geo).bitangent()"),
            "vertexColor": SysValue("\(geo).color()"),
        ]
        switch stage {
        case .surface:
            s["tangent"] = SysValue("\(geo).tangent()")
            s["viewDirection"] = SysValue("\(geo).view_direction()")
            s["screenPosition"] = SysValue("\(geo).screen_position()")
            // The only channel from the geometry stage to the surface stage (spec §23 preamble,
            // §24.8): the geometry function writes it, this reads it back. Absent from the
            // `.geometry` branch on purpose — it does not exist there, and that omission is what
            // makes `input.customAttribute`'s surface-only legality derived rather than declared
            // (`NodeDef.stages`).
            s["customAttribute"] = SysValue("\(geo).custom_attribute()")
        case .geometry:
            s["vertexID"] = SysValue("int(\(geo).vertex_id())")
        }
        return s
    }

    /// `params.textures().custom()` is the only general-purpose sampler a `CustomMaterial` has
    /// (spec §23.6). It yields `half4`; the graph works in `float4`. The y flip matches the
    /// bottom-left UV convention the rest of the app uses and Apple's own USD examples.
    ///
    /// `MaterialCodegen` hoists this into a per-slot local (`texture2d<half> tex0 = …;`) by
    /// reading this constant rather than spelling the string itself
    /// (`MaterialCodegen.swift:128,147`), so the generator and `knownAccessors` below can never
    /// drift apart — spec §24.5's whole reason for existing: two places answering the same
    /// question must be one place, not two that happen to agree.
    static let materialTextureAccessor = "params.textures().custom()"

    /// `realitykit::surface_parameters`'s own surface handle — `MaterialCodegen` hoists it into
    /// `auto surface = …;` at the top of the exported surface function. Named once, here, for the
    /// same reason as `materialTextureAccessor` above: the generator and `knownAccessors` must read
    /// one spelling, not two that happen to agree.
    static let materialSurfaceAccessor = "params.surface()"

    /// `realitykit::{surface,geometry}_parameters`'s geometry handle. The surface stage reads it
    /// inline through every `{sys.…}` accessor (`materialSys(for:)` above); the geometry stage
    /// additionally hoists it into `auto geo = …;` (`MaterialCodegen.swift:149`) because every
    /// accessor there goes through that local. One spelling for both uses, for the same reason as
    /// the two constants above.
    static let materialGeometryAccessor = "params.geometry()"

    static func materialSample(_ slot: TextureSlot, _ uv: String) -> String {
        "float4(\(slot.fragmentName).sample(mn_sampler, float2((\(uv)).x, 1.0 - (\(uv)).y)))"
    }

    /// The surface shader: `params` is `realitykit::surface_parameters`, uniforms read `u`.
    /// `MaterialCodegen` swaps `uniform` for a literal speller when it emits the export.
    ///
    /// `knownAccessors` lists every accessor chain `MaterialCodegen` hoists into a local at the
    /// top of the surface function, beyond what `sys` itself already covers through
    /// `materialGeometryAccessor` — see `everyAccessorTheGeneratorEmitsIsAllowedUnderItsOwnStage`
    /// (`LegalityPredicateTests.swift`) for the correspondence test that catches this list falling
    /// behind what the generator actually emits.
    public static let realityKitSurface = EmitEnvironment(
        uniform: fragment.uniform,
        sys: materialSys(for: .surface),
        textureSample: materialSample,
        textureName: { $0.fragmentName },
        knownAccessors: [materialTextureAccessor, materialSurfaceAccessor])

    /// The geometry modifier: `geo` is `params.geometry()`, hoisted into a local by the assembler
    /// because every accessor goes through it and RealityKit's own examples do the same.
    ///
    /// `knownAccessors` mirrors `realityKitSurface`'s above, for the geometry function's own
    /// hoisted locals.
    public static let realityKitGeometry = EmitEnvironment(
        uniform: fragment.uniform,
        sys: materialSys(for: .geometry),
        textureSample: materialSample,
        textureName: { $0.fragmentName },
        knownAccessors: [materialTextureAccessor, materialGeometryAccessor])

    /// The environment a RealityKit material emits `stage`'s own root-graph statements in. The one
    /// place a stage is turned into a vocabulary, so `NodeDef.stages` and `MaterialValidation`
    /// cannot answer the same question from two different tables (spec §24.5).
    public static func materialEnvironment(for stage: MaterialStage) -> EmitEnvironment {
        switch stage {
        case .surface: realityKitSurface
        case .geometry: realityKitGeometry
        }
    }

    /// Every environment `target`'s program emits a *root-graph* node in — two under `.realityKit`,
    /// one everywhere else. A node is illegal under the target when no environment in this list can
    /// spell what it reads; which of two stages can is rule 2's separate question.
    ///
    /// A node inside a group *definition* is not judged by this list: one emitted function serves
    /// every target and every caller, so its environment is `groupFunction`, whatever the document's
    /// target (spec §23.4).
    public static func environments(for target: OutputTarget) -> [EmitEnvironment] {
        switch target {
        case .fragment: [fragment]
        case .stitchable(.layerEffect): [layerExport]
        case .stitchable: [stitchableFunction]
        case .realityKit: MaterialStage.allCases.map(materialEnvironment(for:))
        }
    }

    /// The `sys` dictionary `Emitter` hands a node: spellings only, with every fill-only entry
    /// dropped rather than flattened away.
    ///
    /// `SysValue.readable` is the whole point of `sys` being a struct: under RealityKit `mouse`
    /// spells `float2(0.0, 0.0)` so a group call's argument list still type-checks, and a body
    /// handed that string would read a plausible-looking constant as if it were the pointer
    /// position — a silently wrong value that `canEmit` had already reported `.missing` for. Absent
    /// is the loud failure; present-but-lying is the quiet one.
    ///
    /// This reaches **every** body kind, not just `.custom`: `EmitContext.sys` is what
    /// `Emitter.substitute` resolves `{sys.…}` against for `.template` and `.variants` bodies too,
    /// and a name that is absent there substitutes to `/* ?sys.name */` — a marker the generator's
    /// own tests already treat as a defect. So this is the backstop for the whole legality
    /// predicate: if `canEmit` and emission ever disagree about a name, the generated source says
    /// so out loud instead of quietly computing with a neutral literal.
    public var readableSys: [String: String] {
        sys.compactMapValues { $0.readable ? $0.spelling : nil }
    }

    /// `custom_parameter()`'s four components, in the order `settings.liveParameters` fills them
    /// (spec §24.6): index 0 is `.x`, and so on. The one spelling `bakedUniforms` below and
    /// `MaterialExport`'s header/snippet both index into, so the two can never drift apart — this
    /// milestone has already paid for two hand-kept copies of one fact going out of step more than
    /// once (spec §24.5, §24.10).
    public static let liveParameterComponents = ["x", "y", "z", "w"]

    /// Uniform reads spelled as the value the document holds right now (spec §23.6), except a field
    /// whose path is one of `document.settings.liveParameters` (spec §24.6): that one reads the
    /// `CustomMaterial`'s single `float4` instead of a literal, at the component its index in the
    /// list picks — 0 is `.x`, 1 is `.y`, and so on — so up to four parameters can animate from
    /// Swift without a re-export.
    ///
    /// Gated on `layout.liveField(for: path) != nil`, not a re-spelled `f.type == .float`: if
    /// `MaterialValidation.liveParameterDiagnostics` ever missed a non-float live path (or a caller
    /// reaches this without validating first), the wrong move is to fall through to a normal baked
    /// literal, not to spell `custom_parameter().x` for a `float2` field — `length(float)` is
    /// ambiguous MSL, and a silently mistyped accessor is worse than a value that just doesn't
    /// animate. `liveField(for:)` is the one place that question is asked — `MaterialExport.liveParameters`
    /// asks the identical question of the identical function, so the two can't drift the way two
    /// independently spelled copies of "is this field legal to substitute" already did once
    /// (`vector.dot`, fix round 2). Snapshotted against `layout` up front so the returned closure
    /// captures only strings and stays `Sendable`.
    public static func bakedUniforms(layout: UniformLayout, document: ShaderDocument,
                                     registry: NodeRegistry) -> @Sendable (UniformField) -> String {
        let live = document.settings.liveParameters
        var mutableLiterals: [String: String] = [:]
        for f in layout.fields {
            guard let path = f.path else { continue }
            if let index = live.firstIndex(of: path), index < liveParameterComponents.count,
               layout.liveField(for: path) != nil {
                mutableLiterals[f.name] = "params.uniforms().custom_parameter().\(liveParameterComponents[index])"
                continue
            }
            let value = ParamValues.value(for: path, in: document, registry: registry)
            mutableLiterals[f.name] = value.map { ParamValues.mslLiteral($0, as: f.type) }
                ?? ParamValues.mslLiteral(.float(0), as: f.type)
        }
        let literals = mutableLiterals
        return { field in literals[field.name] ?? ParamValues.mslLiteral(.float(0), as: field.type) }
    }

    /// Whether a node with a given body can be emitted here — spec §24.5's legality predicate.
    public enum Legality: Equatable, Sendable {
        case allowed
        /// The `{sys.…}` name (or, for `canEmit(mslText:)`, the textual accessor) this body reads
        /// that has no readable spelling in this environment.
        case missing(String)
    }

    /// Whether one template's placeholders are legal here: every `{sys.…}` name it *reads* must
    /// have a readable spelling in this environment (spec §24.5).
    private func canEmitTemplate(_ text: String) -> Legality {
        for m in text.matches(of: NodeRegistry.placeholderPattern) where m.1 == "sys" {
            let name = String(m.2)
            guard let v = sys[name], v.readable else { return .missing(name) }
        }
        return .allowed
    }

    /// Whether a node with this body can be emitted here (spec §24.5). `chosen` selects which
    /// case of a `.variants` body is actually reached — but when `chosen` is `nil` or names a case
    /// the table doesn't have (the predicate asked before the enum param resolved, or with a stale
    /// case name), there is no single case to trust, so *every* case is checked and the body is
    /// refused if any one of them is illegal. A refusal predicate that defaults to "legal" when it
    /// doesn't know which case will run is the wrong way to fail.
    ///
    /// `.custom` bodies are a library escape hatch whose text is a Swift closure, not scannable
    /// MSL — see the doc comment on `NodeBody.custom` and this task's report for why `.allowed` is
    /// the right default rather than a token-level guess.
    public func canEmit(_ body: NodeBody, chosen: String?) -> Legality {
        switch body {
        case .template(let t):
            return canEmitTemplate(t)
        case .variants(_, let table):
            let texts: [String]
            if let chosen, let t = table[chosen] {
                texts = [t]
            } else {
                texts = table.sorted { $0.key < $1.key }.map(\.value)
            }
            for t in texts {
                let result = canEmitTemplate(t)
                if result != .allowed { return result }
            }
            return .allowed
        case .custom:
            return .allowed
        }
    }

    /// The identifier roots that name a RealityKit environment accessor at all, textually —
    /// `params.` and `geo.`, derived rather than hardcoded so a third stage or root stays
    /// self-maintaining. Deliberately the union of both stage vocabularies, never derived from
    /// `self.sys` alone: `fragment`'s own spellings (`in.uv`, `u.time`, …) contain no dotted call
    /// chain at all, so a per-environment derivation would yield an empty root set under
    /// `fragment` and silently stop checking any accessor there.
    private static let accessorRoots: Set<String> = {
        let spellings = Array(materialSys(for: .surface).values) + Array(materialSys(for: .geometry).values)
        let chains = spellings.flatMap { MSLScanner.accessorCalls(in: $0.spelling) }
        return Set(chains.compactMap { chain -> String? in
            guard let dot = chain.firstIndex(of: ".") else { return nil }
            return String(chain[chain.startIndex...dot])
        })
    }()

    /// Every accessor chain a spelling's own text passes through, prefixes included:
    /// `params.geometry().normal()` contributes `params.geometry()` as well as the full chain, and
    /// `int(geo.vertex_id())` contributes `geo.vertex_id()` (the cast wrapping it is not part of
    /// the chain). That is what lets hand-written code hoist a mid-chain accessor into a local
    /// (`auto g = params.geometry();`) or read a value this environment itself only reaches
    /// through a cast, and still check out (spec §24.5).
    private static func accessorPrefixes(of chain: String) -> [String] {
        var prefixes: [String] = []
        var searchStart = chain.startIndex
        while let closeRange = chain.range(of: "()", range: searchStart..<chain.endIndex) {
            prefixes.append(String(chain[chain.startIndex..<closeRange.upperBound]))
            searchStart = closeRange.upperBound
        }
        return prefixes
    }

    /// The same question as `canEmit(_:chosen:)` for hand-written MSL, which names accessors
    /// textually rather than through a `{sys.…}` placeholder (spec §24.5). `known` is derived from
    /// this environment's own vocabulary — every accessor chain (and every prefix of it) a
    /// readable `sys` spelling or a `knownAccessors` entry passes through — so an accessor this
    /// environment's own vocabulary reaches, however it is mid-chain hoisted into a local or
    /// nested inside a cast, always checks out. Whether an *unmatched* chain is refused at all is
    /// a separate gate: only a chain whose root is a RealityKit accessor namespace
    /// (`accessorRoots`) counts as a mistaken read; anything else — a user's own helper-struct
    /// calls, ordinary MSL like `foo.bar().baz()` — is left to the Metal compiler. A missed
    /// diagnostic on code that's already broken is far cheaper than refusing valid code the
    /// predicate can't actually judge.
    public func canEmit(mslText: String) -> Legality {
        let sysChains = sys.values.filter(\.readable).flatMap { MSLScanner.accessorCalls(in: $0.spelling) }
        let known = Set((sysChains + Array(knownAccessors)).flatMap(EmitEnvironment.accessorPrefixes))
        for accessor in MSLScanner.accessorCalls(in: mslText) where !known.contains(accessor) {
            if EmitEnvironment.accessorRoots.contains(where: { accessor.hasPrefix($0) }) {
                return .missing(accessor)
            }
        }
        return .allowed
    }
}
