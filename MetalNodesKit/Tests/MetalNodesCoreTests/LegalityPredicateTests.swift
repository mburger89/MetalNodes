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
}
