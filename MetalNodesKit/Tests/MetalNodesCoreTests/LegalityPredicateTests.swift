import Testing
@testable import MetalNodesCore

@Suite struct LegalityPredicateTests {
    private func body(_ t: String) -> NodeBody { .template(t) }

    @Test func aNodeReadingAKeyTheEnvironmentHasIsAllowed() {
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.uv};"), chosen: nil) == .allowed)
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.worldPosition};"), chosen: nil) == .allowed)
    }

    @Test func aNodeReadingAMissingKeyIsRefused() {
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.worldPosition};"), chosen: nil)
                == .missing("worldPosition"))
        #expect(EmitEnvironment.realityKitGeometry.canEmit(body("{out.x} = {sys.tangent};"), chosen: nil)
                == .missing("tangent"))
    }

    /// The wrinkle §24.5 exists for: the material environments *do* spell `resolution` and
    /// `mouse`, as neutral literals for group-call argument lists — but a node may not read them.
    @Test func fillOnlyKeysArePresentButNotReadable() {
        #expect(EmitEnvironment.realityKitSurface.sys["resolution"] != nil)
        #expect(EmitEnvironment.realityKitSurface.sys["resolution"]?.readable == false)
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.resolution};"), chosen: nil)
                == .missing("resolution"))
        #expect(EmitEnvironment.realityKitSurface.canEmit(body("{out.x} = {sys.mouse};"), chosen: nil)
                == .missing("mouse"))
    }

    @Test func theSameKeysStayReadableInTheFragmentEnvironment() {
        #expect(EmitEnvironment.fragment.sys["resolution"]?.readable == true)
        #expect(EmitEnvironment.fragment.canEmit(body("{out.x} = {sys.mouse};"), chosen: nil) == .allowed)
    }

    /// A `.variants` body is only as legal as the case actually chosen.
    @Test func variantsAreCheckedForTheChosenCaseOnly() {
        let b = NodeBody.variants(param: "mode", [
            "plain": "{out.x} = {sys.uv};",
            "aspect": "{out.x} = {sys.uv} * {sys.resolution};",
        ])
        #expect(EmitEnvironment.realityKitSurface.canEmit(b, chosen: "plain") == .allowed)
        #expect(EmitEnvironment.realityKitSurface.canEmit(b, chosen: "aspect") == .missing("resolution"))
    }

    /// A refusal predicate that doesn't know which case will run must not default to "legal": with
    /// no `chosen` case (or a stale one absent from the table), every case is checked, and the body
    /// is refused if *any* one of them reads a key this environment can't serve.
    @Test func variantsWithNoResolvedCaseAreCheckedAcrossEveryCase() {
        let allBad = NodeBody.variants(param: "mode", ["only": "{out.x} = {sys.worldPosition};"])
        #expect(EmitEnvironment.fragment.canEmit(allBad, chosen: nil) == .missing("worldPosition"))
        #expect(EmitEnvironment.fragment.canEmit(allBad, chosen: "nope") == .missing("worldPosition"))

        let allGood = NodeBody.variants(param: "mode", ["only": "{out.x} = {sys.uv};"])
        #expect(EmitEnvironment.fragment.canEmit(allGood, chosen: nil) == .allowed)
    }

    /// `.custom` bodies are a library escape hatch — a Swift closure, not scannable MSL — and are
    /// always allowed. The registry's one real `.custom` body (`output.material`) reads nothing
    /// from `sys` at all, so this can never mask a genuine refusal today.
    @Test func customBodiesAreAlwaysAllowed() {
        let c = NodeBody.custom { _ in [] }
        #expect(EmitEnvironment.fragment.canEmit(c, chosen: nil) == .allowed)
        #expect(EmitEnvironment.realityKitSurface.canEmit(c, chosen: nil) == .allowed)
    }

    /// Custom MSL names accessors textually rather than through a placeholder (spec §24.5).
    @Test func textualAccessorsAreCheckedAgainstTheEnvironment() {
        #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: "out = params.geometry().normal().x;") == .allowed)
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = params.geometry().normal().x;")
                == .missing("params.geometry().normal()"))
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = in_a * 2.0;") == .allowed)
    }

    /// `known` must hold every accessor *prefix* a spelling's text passes through, not only the
    /// spelling's own maximal chain — otherwise the predicate refuses code that mirrors what the
    /// generator itself produces. Three concrete cases the generator emits or a user would
    /// naturally write, each of which must be allowed.
    @Test func accessorPrefixesEmbeddedInASpellingAreKnown() {
        // `vertexID`'s own spelling is `int(geo.vertex_id())` — a cast around the chain, not the
        // chain itself. There must be text a user can legally write to read the vertex id.
        #expect(EmitEnvironment.realityKitGeometry.canEmit(mslText: "out = float(geo.vertex_id());") == .allowed)

        // Hoisting `params.geometry()` into a local is the same idiom `realityKitGeometry` itself
        // uses for `geo` — a prefix of a known chain (`params.geometry().normal()`), not the whole
        // chain, must still check out on its own.
        #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: "auto g = params.geometry(); out = g.normal().x;") == .allowed)

        // `params.textures().custom()` is emitted verbatim by `MaterialCodegen` into every
        // generated material (`MaterialCodegen.swift:128,147`) — hand-written code that reads it
        // must not be refused by the very predicate meant to guard the generator's own output.
        #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: "out = params.textures().custom().sample(s, uv);") == .allowed)
    }

    /// The prefix fix must not turn the predicate into a rubber stamp: a chain rooted in a real
    /// RealityKit accessor namespace but naming something this environment never spells is still
    /// refused.
    @Test func aGenuinelyAbsentAccessorIsStillRefused() {
        #expect(EmitEnvironment.realityKitGeometry.canEmit(mslText: "out = params.geometry().tangent();")
                == .missing("params.geometry().tangent()"))
    }

    /// The accessor-root gate is derived from the union of both RealityKit stage vocabularies, not
    /// from `self.sys` alone — `fragment`'s own spellings have no dotted call chain at all, so a
    /// per-environment derivation would silently stop checking any accessor there. This is the
    /// brief's own case (`textualAccessorsAreCheckedAgainstTheEnvironment` above): it must keep
    /// refusing a RealityKit accessor read under `fragment`.
    @Test func theAccessorRootGateAppliesEvenWhereThisEnvironmentHasNoChainOfItsOwn() {
        #expect(EmitEnvironment.fragment.sys.values.allSatisfy { MSLScanner.accessorCalls(in: $0.spelling).isEmpty })
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = geo.uv0();") == .missing("geo.uv0()"))
    }

    /// The correspondence invariant a hand-maintained `knownAccessors` list cannot itself
    /// guarantee: every accessor chain `MaterialCodegen` actually emits into a stage's function
    /// body must be `.allowed` under that stage's own `EmitEnvironment`. Derived from real
    /// generated output — not a fixed list of strings someone remembered to update — so a fourth
    /// accessor the generator starts emitting fails here immediately. Same shape as the
    /// `materialSys`/shim correspondence test (`MaterialCompileTests.swift`,
    /// `everyMaterialSysSpellingResolvesAgainstItsShim`).
    ///
    /// The graph below reaches all three accessors the generator currently emits per stage
    /// (`params.textures().custom()`, `params.surface()`, `params.geometry()`), by wiring a real
    /// Texture Sample node into each stage. Both samples name the *same* asset — a RealityKit
    /// material has one texture slot (`MaterialValidation`'s Rule 4), and two nodes reading the
    /// same image both resolve to that one slot and export cleanly.
    @Test func everyAccessorTheGeneratorEmitsIsAllowedUnderItsOwnStage() throws {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let asset = AssetID()
        var surfaceSample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        surfaceSample.params["asset"] = .asset(asset)
        var geometrySample = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
        geometrySample.params["asset"] = .asset(asset)
        for n in [terminal, surfaceSample, geometrySample] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(surfaceSample.id, "color")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(geometrySample.id, "color")
        doc.root = g

        let shader = try ShaderGenerator.generate(doc, target: .realityKit)
        let export = try #require(shader.exportSource)
        let names = MaterialCodegen.functionNames(exportName: doc.settings.exportName)

        let surfaceBody = try #require(Self.functionBody(named: names.surface, in: export))
        let geometryBody = try #require(Self.functionBody(named: names.geometry, in: export))

        let surfaceChains = MSLScanner.accessorCalls(in: surfaceBody)
        let geometryChains = MSLScanner.accessorCalls(in: geometryBody)
        // Guard the guard: if the graph above stops reaching real generated accessors at all, an
        // empty chain list would make the loops below pass vacuously.
        #expect(surfaceChains.contains("params.textures().custom()"))
        #expect(geometryChains.contains("params.textures().custom()"))

        for chain in surfaceChains {
            #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: chain) == .allowed,
                    "surface emitted \(chain), which its own environment refuses")
        }
        for chain in geometryChains {
            #expect(EmitEnvironment.realityKitGeometry.canEmit(mslText: chain) == .allowed,
                    "geometry emitted \(chain), which its own environment refuses")
        }
    }

    /// The text of one `[[visible]] void <name>(...) { ... }` function, braces included, found by
    /// matching braces from the function's declared name — good enough for this generator's own
    /// output, which never nests a same-named function.
    private static func functionBody(named name: String, in source: String) -> String? {
        guard let sigRange = source.range(of: "void \(name)(") else { return nil }
        guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var i = openBrace
        while i < source.endIndex {
            if source[i] == "{" { depth += 1 }
            if source[i] == "}" {
                depth -= 1
                if depth == 0 { return String(source[openBrace...i]) }
            }
            i = source.index(after: i)
        }
        return nil
    }
}

/// The migration test. `NodeDef.stages` stopped being declared and started being derived from the
/// emit environments; this suite is what makes that safe to land rather than hopeful.
@Suite struct DerivedStagesTests {
    /// What §23.3 declared by hand, before this task derived it. If a value here changes, either
    /// the vocabulary changed on purpose or the derivation is wrong — never edit this table to
    /// make the test pass.
    static let declared: [String: Set<MaterialStage>] = [
        "input.worldPosition": MaterialStage.all,
        "input.modelPosition": MaterialStage.all,
        "input.normal3d": MaterialStage.all,
        "input.bitangent": MaterialStage.all,
        "input.uv1": MaterialStage.all,
        "input.vertexColor": MaterialStage.all,
        "input.tangent": [.surface],
        "input.viewDirection": [.surface],
        "input.screenPosition": [.surface],
        "input.vertexID": [.geometry],
    ]

    @Test func everyDerivedStageSetMatchesWhatWasDeclared() {
        for (id, expected) in Self.declared {
            let def = NodeRegistry.builtin[id]
            #expect(def?.stages == expected, "\(id)")
        }
    }

    /// Every node that reads no stage-specific value is legal in both stages, and that must not
    /// have quietly changed either.
    @Test func stageAgnosticNodesStayAgnostic() {
        for id in ["math.mix", "noise.value", "input.float", "input.time", "input.uv", "color.invert"] {
            #expect(NodeRegistry.builtin[id]?.stages == MaterialStage.all, "\(id)")
        }
    }

    /// The one place the migration found the *declaration* wrong rather than the derivation.
    ///
    /// `input.mouse` and `input.resolution` declared `MaterialStage.all` — the stored property's
    /// default, never revisited — while §23.7 rule 3 refused them under RealityKit from a separate
    /// hand-listed set (`twoDimensionalOnly`). Two answers to one question, and they contradicted
    /// each other: the declaration said "legal in both material stages", the rule said "legal in
    /// neither". `materialSys` spells both names `readable: false`, so `[]` is the truth, and the
    /// derivation reaches it without being told.
    ///
    /// No defect shipped from the stale declaration — rule 3 caught these two nodes first, and
    /// rule 2 was the only reader of `stages` — but a wrong value sitting in a public property
    /// waiting for a second reader is exactly the seam handoff §14.6 blames for two M7 defects.
    static let declarationWasWrong: [String: Set<MaterialStage>] = [
        "input.mouse": [],
        "input.resolution": [],
    ]

    @Test func theStaleDeclarationsNowDeriveTheTruth() {
        for (id, expected) in Self.declarationWasWrong {
            #expect(NodeRegistry.builtin[id]?.stages == expected, "\(id)")
        }
    }

    /// The rest of the migration: every *other* builtin declared `MaterialStage.all` — the stored
    /// property's default — so the derivation has to keep answering "both" for all of them. The
    /// two tables above plus this loop cover the whole library, not a sample of it.
    @Test func everyOtherBuiltinWasDeclaredBothStagesAndStillDerivesBoth() {
        // Guard the guard: this is a loop over a registry, so an empty or shrunken one would pass
        // it vacuously and the migration's whole-library claim would quietly stop being true. The
        // library held 55 builtins when the derivation landed, 43 of them outside the two tables
        // (measured, not computed); the floor only has to be tight enough that "the loop ran over
        // the real library" stays a fact rather than an assumption.
        let checked = NodeRegistry.builtin.all
            .filter { Self.declared[$0.id] == nil && Self.declarationWasWrong[$0.id] == nil }
        #expect(checked.count >= 40)
        // …and both tables name real nodes, so a renamed id cannot silently empty them either.
        for id in Self.declared.keys { #expect(NodeRegistry.builtin[id] != nil, "\(id)") }
        for id in Self.declarationWasWrong.keys { #expect(NodeRegistry.builtin[id] != nil, "\(id)") }

        for def in checked {
            #expect(def.stages == MaterialStage.all, "\(def.id)")
        }
    }

    /// The hole the fail-closed `.variants` rule opens if a call site forgets to resolve the case:
    /// UV's `aspect` variant reads `{sys.resolution}`, which no material stage lets a node read, so
    /// asking with `chosen: nil` refuses UV outright and quietly removes a working node from the
    /// RealityKit target. The derivation must ask about the case the node actually emits.
    @Test func theUVNodeStaysLegalUnderBothStagesBecauseItsDefaultCaseIsResolved() throws {
        let uv = try #require(NodeRegistry.builtin["input.uv"])
        #expect(uv.defaultVariantCase == "normalized")
        #expect(uv.stages == MaterialStage.all)
        for stage in MaterialStage.allCases {
            #expect(EmitEnvironment.materialEnvironment(for: stage)
                .canEmit(uv.body, chosen: uv.defaultVariantCase) == .allowed, "\(stage)")
            // …and this is the answer the unresolved question would have given.
            #expect(EmitEnvironment.materialEnvironment(for: stage)
                .canEmit(uv.body, chosen: nil) == .missing("resolution"), "\(stage)")
        }
    }

    /// The instance's own case, not just the type's default: a UV node the user switched to
    /// `aspect` really does read a value this target cannot supply.
    @Test func anInstanceResolvesItsOwnVariantCase() throws {
        let uv = try #require(NodeRegistry.builtin["input.uv"])
        let plain = NodeInstance(kind: .builtin("input.uv"), position: .zero)
        let aspect = NodeInstance(kind: .builtin("input.uv"), position: .zero, params: ["mode": .enumCase("aspect")])
        let stale = NodeInstance(kind: .builtin("input.uv"), position: .zero, params: ["mode": .enumCase("gone")])
        #expect(uv.variantCase(for: plain) == "normalized")
        #expect(uv.variantCase(for: aspect) == "aspect")
        // A hand-edited or renamed case falls back to the default, exactly as `Emitter` does.
        #expect(uv.variantCase(for: stale) == "normalized")
    }
}

/// The behaviours §23.7 rules 2 and 3 gave, now produced by one predicate rather than three
/// hand-maintained sets.
@Suite struct LegalityRefactorTests {
    private func doc(_ nodeID: String, target: OutputTarget) -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.target = target
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin(GraphValidator.terminalID(for: target)), position: .zero)
        let n = NodeInstance(kind: .builtin(nodeID), position: .zero)
        g.nodes[terminal.id] = terminal; g.nodes[n.id] = n
        if let out = NodeRegistry.builtin[nodeID]?.outputs.first {
            let socket = target == .realityKit ? "baseColor" : "color"
            g.inputs[SocketRef(terminal.id, socket)] = SocketRef(n.id, out.name)
        }
        d.root = g
        return d
    }

    private func errors(_ d: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: d, registry: .builtin, target: d.settings.target)
            .filter { $0.severity == .error }
    }

    @Test func mouseAndResolutionStayRefusedUnderRealityKit() {
        #expect(!errors(doc("input.mouse", target: .realityKit)).isEmpty)
        #expect(!errors(doc("input.resolution", target: .realityKit)).isEmpty)
    }

    @Test func threeDimensionalNodesStayRefusedUnderFragment() {
        #expect(!errors(doc("input.worldPosition", target: .fragment)).isEmpty)
        #expect(!errors(doc("input.vertexID", target: .fragment)).isEmpty)
    }

    @Test func legalCombinationsStayLegal() {
        #expect(errors(doc("input.worldPosition", target: .realityKit)).isEmpty)
        #expect(errors(doc("input.mouse", target: .fragment)).isEmpty)
        #expect(errors(doc("noise.value", target: .realityKit)).isEmpty)
    }

    /// The HARD case: UV is a `.variants` node, and a legality question asked without the resolved
    /// case refuses it. The default-cased node must stay usable under RealityKit.
    @Test func theUVNodeStaysUsableUnderRealityKit() {
        #expect(errors(doc("input.uv", target: .realityKit)).isEmpty)
    }
}

/// The hole deriving the rule closes. §23.7 rule 3 was a list of two node *ids*, so it saw the
/// Resolution node and missed the UV node's `aspect` variant, which reads `{sys.resolution}` just
/// as directly. A predicate that reads bodies cannot miss it.
@Suite struct VariantLegalityTests {
    private func errors(_ d: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: d, registry: .builtin, target: d.settings.target)
            .filter { $0.severity == .error }
    }

    private func materialDoc(mode: String?) -> ShaderDocument {
        MaterialFixture.document { g in
            let id = MaterialFixture.wire("input.uv", into: "baseColor", &g)
            if let mode { g.nodes[id]!.params["mode"] = .enumCase(mode) }
        }
    }

    /// Under RealityKit this variant emitted `(uv - 0.5) * (float2(1.0, 1.0) / 1.0)` — centred UV,
    /// silently not the aspect-corrected UV the user asked for, because `resolution` is a fill-only
    /// spelling there. A behaviour change from M7, and the intended one: the rule now refuses every
    /// read of a value this target cannot supply, not just the two nodes someone listed.
    @Test func theAspectVariantIsRefusedUnderRealityKit() {
        #expect(errors(materialDoc(mode: "aspect")).contains {
            $0.message.contains("reads resolution, which the RealityKit Material target does not provide")
        })
    }

    /// The other half of the hard requirement: the *default*-cased node, which is what the library
    /// hands the user, stays legal. A predicate asked without the resolved case would fail closed
    /// and delete the UV node from this target.
    @Test func theDefaultVariantStaysLegalUnderRealityKit() {
        #expect(errors(materialDoc(mode: nil)).isEmpty)
        #expect(errors(materialDoc(mode: "normalized")).isEmpty)
        // A stale case falls back to the default, so legality must not refuse it — the only error
        // it earns is the pre-existing "not a valid option" one, from the param rule that owns it.
        let stale = errors(materialDoc(mode: "renamedAway"))
        #expect(stale.allSatisfy { $0.message.contains("is not a valid option") })
    }

    @Test func bothVariantsStayLegalUnderTheFragmentTarget() {
        for mode in ["normalized", "aspect"] {
            var d = ShaderDocument()
            var g = Graph()
            let out = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
            let uv = NodeInstance(kind: .builtin("input.uv"), position: .zero, params: ["mode": .enumCase(mode)])
            g.nodes[out.id] = out; g.nodes[uv.id] = uv
            g.inputs[SocketRef(out.id, "color")] = SocketRef(uv.id, "uv")
            d.root = g
            #expect(errors(d).isEmpty, "\(mode)")
        }
    }
}

/// The seam `Emitter` hands a `.custom` body. `sys` is a dictionary of `SysValue`, and flattening
/// it with `mapValues(\.spelling)` threw away the one bit that makes the fill-only entries safe.
@Suite struct ReadableSysTests {
    @Test func fillOnlySpellingsAreDroppedRatherThanFlattened() {
        let surface = EmitEnvironment.realityKitSurface
        // Present in `sys` — group-call argument lists need them to spell as *something*…
        #expect(surface.sys["mouse"] != nil)
        #expect(surface.sys["resolution"] != nil)
        // …and absent from what a body is handed, so reading one is a missing key, not a lie.
        #expect(surface.readableSys["mouse"] == nil)
        #expect(surface.readableSys["resolution"] == nil)
        #expect(surface.readableSys["uv"] == surface.sys["uv"]?.spelling)
    }

    @Test func everyReadableSpellingSurvivesInEveryEnvironment() {
        for env in [EmitEnvironment.fragment, .groupFunction, .stitchableFunction, .layerExport,
                    .realityKitSurface, .realityKitGeometry] {
            for (name, value) in env.sys where value.readable {
                #expect(env.readableSys[name] == value.spelling, "\(name)")
            }
            #expect(env.readableSys.count == env.sys.values.filter(\.readable).count)
        }
    }

    /// `canEmit` and `readableSys` must agree about what a body may read: a name the predicate
    /// reports `.missing` must not then arrive in the context as a usable string.
    @Test func whatTheEnvironmentRefusesIsAlsoWhatItWithholds() {
        for env in [EmitEnvironment.fragment, .realityKitSurface, .realityKitGeometry] {
            for name in EmitEnvironment.sysNames {
                let allowed = env.canEmit(.template("{out.x} = {sys.\(name)};"), chosen: nil) == .allowed
                #expect(allowed == (env.readableSys[name] != nil), "\(name)")
            }
        }
    }

    /// The library's only `.custom` body is the Material Output terminal, which emits no statement
    /// at all — so withholding the fill-only spellings cannot change any generated program today.
    @Test func theOnlyCustomBodyInTheLibraryReadsNothing() {
        let customs = NodeRegistry.builtin.all.filter { if case .custom = $0.body { true } else { false } }
        #expect(customs.map(\.id) == ["output.material"])
        for def in customs {
            guard case .custom(let emit) = def.body else { continue }
            let ctx = EmitContext(inputs: [:], outputs: [:], params: [:], enums: [:], types: [:])
            #expect(emit(ctx).isEmpty, "\(def.id)")
        }
    }
}

/// The third guard family: an accessor a hand-written Custom MSL body cannot reach from where it
/// is emitted (spec §24.5). A `.msl` definition becomes a *group function* body, and that
/// function's parameters are `(float2 uv, float time, float2 size, float2 mouse, …)` — `params`
/// and `geo` are not in scope there under any document target.
@Suite struct CustomMSLAccessorTests {
    private func definitionDoc(_ body: String, target: OutputTarget = .realityKit) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = target
        var def = GroupDefinition(name: "W")
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl(body)
        doc.definitions[def.id] = def
        var g = Graph()
        let t = NodeInstance(kind: .builtin(GraphValidator.terminalID(for: target)), position: .zero)
        let i = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[t.id] = t; g.nodes[i.id] = i
        doc.root = g
        return doc
    }

    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
            .filter { $0.severity == .error }
    }

    @Test(arguments: [OutputTarget.realityKit, .fragment, .stitchable(.layerEffect)])
    func aRealityKitAccessorIsRefusedWhateverTheDocumentTargets(_ target: OutputTarget) {
        let d = errors(definitionDoc("out = params.geometry().normal().x;", target: target))
        #expect(d.contains { $0.message.contains("params.geometry()") }, "\(target)")
        // The definition names itself, the way the scope-breaker guards do — a definition is not
        // an instance, so there is no node to anchor on.
        #expect(d.first { $0.message.contains("params.geometry()") }?.message.hasPrefix("W: ") == true, "\(target)")
        #expect(d.first { $0.message.contains("params.geometry()") }?.node == nil, "\(target)")
    }

    /// The geometry stage's hoisted `geo` local is just as out of reach from a group function.
    @Test func theHoistedGeometryLocalIsRefusedToo() {
        #expect(errors(definitionDoc("out = float(geo.vertex_id());")).contains { $0.message.contains("geo.vertex_id()") })
    }

    /// The gate stays narrow: a body that calls its own helpers, or nothing at all, is left to the
    /// Metal compiler rather than second-guessed here.
    @Test func ordinaryCustomCodeIsUntouched() {
        #expect(errors(definitionDoc("out = in_a * 2.0 + sin(time);")).isEmpty)
        #expect(errors(definitionDoc("float3 v = float3(uv, 0.0); out = length(v);")).isEmpty)
        #expect(errors(definitionDoc("Helper h; out = h.value().x;")).isEmpty)
    }

    /// The vocabulary a group function *does* have stays available — that is the whole reason the
    /// check is asked of `groupFunction` rather than of the document's target.
    @Test func theGroupFunctionsOwnSystemValuesAreFine() {
        #expect(errors(definitionDoc("out = uv.x * time * size.y * mouse.x;")).isEmpty)
    }

    /// Both guards fire on one body: this file's two families are independent.
    @Test func aScopeBreakerAndAnIllegalAccessorAreBothReported() {
        let d = errors(definitionDoc("return params.surface().base_color();"))
        #expect(d.contains { $0.message.contains("return") })
        #expect(d.contains { $0.message.contains("params.surface()") })
    }
}

/// The production seam `readableSys` exists for: what `Emitter` actually puts in `EmitContext.sys`.
/// `ReadableSysTests` above pins the property; this pins the *call site*, which reverting alone
/// would otherwise leave green.
@Suite struct EmitterSysContextTests {
    /// A node the builtin library deliberately does not contain: a template that reads
    /// `{sys.mouse}` and is nevertheless asked to emit under a material environment. Real
    /// documents cannot reach this — `MaterialValidation` refuses the Mouse node first — which is
    /// exactly why the emitter's own behaviour has to be pinned directly.
    private static let mouseReader = NodeDef(
        id: "test.mouseReader", title: "Mouse Reader", category: .input,
        outputs: [SocketDecl(name: "out", type: .concrete(.float2))],
        body: .template("{out.out} = {sys.mouse};"))

    private func emittedLine(env: EmitEnvironment) throws -> String {
        let registry = try NodeRegistry(BuiltinNodes.all + [Self.mouseReader])
        var doc = ShaderDocument()
        var g = Graph()
        let node = NodeInstance(kind: .builtin(Self.mouseReader.id), position: .zero)
        g.nodes[node.id] = node
        doc.root = g
        let (resolved, diags) = TypeResolver.resolve(g, path: .root, document: doc, registry: registry, order: [node.id])
        #expect(diags.isEmpty)
        let out = Emitter.emit(order: [node.id], graph: g, path: .root, document: doc, registry: registry,
                               resolved: resolved, env: env)
        return try #require(out.bodyLines.first { $0.contains("=") })
    }

    /// The whole point: under RealityKit, `mouse` is spelled but not readable, so the emitted
    /// statement must carry the unresolved marker — loud — rather than `float2(0.0, 0.0)`, which
    /// would compile and silently compute with a constant the user never asked for.
    @Test func aFillOnlySystemValueEmitsTheUnresolvedMarkerRatherThanItsLiteral() throws {
        for env in [EmitEnvironment.realityKitSurface, .realityKitGeometry] {
            let line = try emittedLine(env: env)
            #expect(line.contains("/* ?sys.mouse */"))
            #expect(!line.contains("float2(0.0, 0.0)"))
        }
    }

    /// The control: where `mouse` *is* readable the same node emits the environment's real
    /// spelling, so the test above is measuring `readable`, not a broken emitter.
    @Test func aReadableSystemValueStillEmitsItsSpelling() throws {
        #expect(try emittedLine(env: .fragment).hasSuffix("= u.mouse;"))
        #expect(try !emittedLine(env: .fragment).contains("?sys."))
        // `groupFunction` spells `mouse` as the bare parameter name, so `contains("mouse")` would
        // also be satisfied by `/* ?sys.mouse */` — the very failure this suite exists to catch.
        // Anchored on the whole statement instead, which the marker cannot satisfy.
        #expect(try emittedLine(env: .groupFunction).hasSuffix("= mouse;"))
    }

    /// And the same is true of a readable key under the *material* environments, so the refusal
    /// above is specific to the fill-only entries rather than to RealityKit as a whole.
    @Test func aReadableMaterialSystemValueIsUnaffected() throws {
        let uvReader = NodeDef(id: "test.uvReader", title: "UV Reader", category: .input,
                               outputs: [SocketDecl(name: "out", type: .concrete(.float2))],
                               body: .template("{out.out} = {sys.uv};"))
        let registry = try NodeRegistry(BuiltinNodes.all + [uvReader])
        var doc = ShaderDocument()
        var g = Graph()
        let node = NodeInstance(kind: .builtin(uvReader.id), position: .zero)
        g.nodes[node.id] = node
        doc.root = g
        let (resolved, _) = TypeResolver.resolve(g, path: .root, document: doc, registry: registry, order: [node.id])
        let out = Emitter.emit(order: [node.id], graph: g, path: .root, document: doc, registry: registry,
                               resolved: resolved, env: .realityKitSurface)
        let line = try #require(out.bodyLines.first { $0.contains("=") })
        #expect(line.contains("params.geometry().uv0()"))
        #expect(!line.contains("?sys."))
    }
}

/// The third `canEmit` call site — `MaterialValidation.definitionNodeDiagnostics` — asks about a
/// node inside a group definition, in `groupFunction`'s vocabulary. It must ask with the resolved
/// case for the same reason the other two do: the fail-closed `.variants` rule would otherwise
/// refuse a definition over a case the node will never emit.
///
/// No builtin can show this. Every `.variants` body in the library reads only names `groupFunction`
/// already spells, so `chosen: nil` and `chosen: <case>` agree for all of them — which is precisely
/// why the argument was unpinned. This synthetic node makes the two answers differ.
@Suite struct DefinitionScopeVariantTests {
    private static let modal = NodeDef(
        id: "test.modalReader", title: "Modal Reader", category: .input,
        outputs: [SocketDecl(name: "out", type: .concrete(.float3))],
        params: [ParamDecl(name: "mode", kind: .enumeration(["plain", "world"]),
                           defaultValue: .enumCase("plain"))],
        body: .variants(param: "mode", [
            // Legal in a group function: `uv` is one of its four parameters.
            "plain": "{out.out} = float3({sys.uv}, 0.0);",
            // Not legal there: a group function is target-agnostic and cannot spell RealityKit's
            // geometry accessors at all.
            "world": "{out.out} = {sys.worldPosition};",
        ]))

    /// The node in a reachable definition, wired to that definition's Group Output, under a
    /// RealityKit document — the exact shape `definitionNodeDiagnostics` walks.
    private func document(mode: String?) throws -> (ShaderDocument, NodeRegistry) {
        let registry = try NodeRegistry(BuiltinNodes.all + [Self.modal])
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        var def = GroupDefinition(name: "Wrapper", outputs: [SocketDecl(name: "out", type: .concrete(.float3))])
        var inner = Graph()
        let gin = NodeInstance(kind: .groupInput, position: .zero)
        let gout = NodeInstance(kind: .groupOutput, position: .zero)
        var node = NodeInstance(kind: .builtin(Self.modal.id), position: .zero)
        if let mode { node.params["mode"] = .enumCase(mode) }
        for n in [gin, gout, node] { inner.nodes[n.id] = n }
        inner.inputs[SocketRef(gout.id, "out")] = SocketRef(node.id, "out")
        def.graph = inner
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.material"), position: .zero)
        let instance = NodeInstance(kind: .group(def.id), position: .zero)
        g.nodes[terminal.id] = terminal; g.nodes[instance.id] = instance
        g.inputs[SocketRef(terminal.id, "normal")] = SocketRef(instance.id, "out")
        doc.root = g
        return (doc, registry)
    }

    private func errors(_ pair: (ShaderDocument, NodeRegistry)) -> [Diagnostic] {
        GraphValidator.validate(document: pair.0, registry: pair.1, target: .realityKit)
            .filter { $0.severity == .error }
    }

    /// The case the node actually emits is legal in a group function, so the definition is fine.
    /// Asking without the resolved case checks `world` too and refuses — the regression this pins.
    @Test func aDefinitionIsJudgedOnTheCaseItsNodeActuallyEmits() throws {
        #expect(errors(try document(mode: nil)).isEmpty)
        #expect(errors(try document(mode: "plain")).isEmpty)
    }

    /// The mirror, so the test above cannot pass by the rule having stopped firing altogether: the
    /// same node switched to the case that really does read a RealityKit accessor is refused.
    @Test func theCaseThatDoesReachOutOfScopeIsStillRefused() throws {
        let d = errors(try document(mode: "world"))
        #expect(d.contains { $0.message.contains("Modal Reader") && $0.message.contains("out of the group") })
    }
}
