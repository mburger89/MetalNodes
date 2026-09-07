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

    /// Custom MSL names accessors textually rather than through a placeholder (spec §24.5).
    @Test func textualAccessorsAreCheckedAgainstTheEnvironment() {
        #expect(EmitEnvironment.realityKitSurface.canEmit(mslText: "out = params.geometry().normal().x;") == .allowed)
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = params.geometry().normal().x;")
                == .missing("params.geometry().normal()"))
        #expect(EmitEnvironment.fragment.canEmit(mslText: "out = in_a * 2.0;") == .allowed)
    }
}
