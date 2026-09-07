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

    /// Registry-validation vocabulary only — not every environment's `sys` dictionary supplies every
    /// name (the RealityKit builtins are wired by Task 5). Keeps typos in a node body's `{sys.…}`
    /// placeholder from silently producing a comment marker instead of a diagnostic.
    public static let sysNames: Set<String> = ["uv", "time", "resolution", "mouse", "worldPosition",
                                                "modelPosition", "normal3d", "tangent", "bitangent",
                                                "viewDirection", "uv1", "vertexColor", "vertexID",
                                                "screenPosition"]

    /// A slot sampled by name, y-flipped: the shape every target but the Layer Effect export uses.
    public static func flippedSample(_ name: String, _ uv: String) -> String {
        "\(name).sample(mn_sampler, float2(\(uv).x, 1.0 - \(uv).y))"
    }

    public init(uniform: @escaping @Sendable (UniformField) -> String, sys: [String: SysValue],
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
    /// `resolution` and `mouse` resolve to neutral literals: every group function's signature
    /// starts `(float2 uv, float time, float2 size, float2 mouse, …)` and the UV node's `aspect`
    /// variant reads `{sys.resolution}`, so the keys must produce *something*. No node can observe
    /// them — Resolution and Mouse are refused under this target — and a unit aspect ratio makes
    /// `aspect` degenerate to centred UV rather than to nonsense.
    public static func materialSys(for stage: MaterialStage) -> [String: SysValue] {
        let geo = stage == .surface ? "params.geometry()" : "geo"
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
        case .geometry:
            s["vertexID"] = SysValue("int(\(geo).vertex_id())")
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
        var mutableLiterals: [String: String] = [:]
        for f in layout.fields {
            guard let path = f.path else { continue }
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

    /// Whether a node with this body can be emitted here: every `{sys.…}` name it *reads* must
    /// have a readable spelling in this environment (spec §24.5). `chosen` selects which case of a
    /// `.variants` body is actually reached; the cases not chosen are not asked about at all.
    ///
    /// `.custom` bodies are a library escape hatch whose text is a Swift closure, not scannable
    /// MSL — see the doc comment on `NodeBody.custom` and this task's report for why `.allowed` is
    /// the right default rather than a token-level guess.
    public func canEmit(_ body: NodeBody, chosen: String?) -> Legality {
        let text: String
        switch body {
        case .template(let t): text = t
        case .variants(_, let table): text = chosen.flatMap { table[$0] } ?? ""
        case .custom: return .allowed
        }
        for m in text.matches(of: NodeRegistry.placeholderPattern) where m.1 == "sys" {
            let name = String(m.2)
            guard let v = sys[name], v.readable else { return .missing(name) }
        }
        return .allowed
    }

    /// The same question for hand-written MSL, which names accessors textually rather than
    /// through a `{sys.…}` placeholder (spec §24.5). The accessor set this checks against is
    /// derived from this environment's own readable spellings, so the two can never disagree.
    public func canEmit(mslText: String) -> Legality {
        let known = Set(sys.values.filter(\.readable).map(\.spelling))
        for accessor in MSLScanner.accessorCalls(in: mslText) where !known.contains(accessor) {
            if accessor.hasPrefix("params.") || accessor.hasPrefix("geo.") { return .missing(accessor) }
        }
        return .allowed
    }
}
