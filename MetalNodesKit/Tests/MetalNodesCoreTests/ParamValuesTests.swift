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

    /// A non-finite float component has no MSL literal spelling; the literal path clamps it to
    /// zero the same way `ParamValue.finite` does, rather than emitting `nan` or `inf`.
    @Test func aNonFiniteFloatLiteralIsZero() {
        #expect(ParamValues.mslLiteral(.float(.nan), as: .float) == "0.0")
    }

    /// A value of the wrong shape for the declared type is coerced, not crashed on: a document
    /// hand-edited or migrated from an older schema must still export.
    @Test func aMismatchedValueCoercesToTheDeclaredType() {
        #expect(ParamValues.mslLiteral(.float(1), as: .float3) == "float3(1.0, 1.0, 1.0)")
        #expect(ParamValues.mslLiteral(.float3(.init(1, 2, 3)), as: .float) == "1.0")
    }

    /// An `.int` slot must coerce exactly the way `UniformImage.write`'s byte path coerces —
    /// round to nearest (not truncate), clamp NaN to 0, clamp out-of-range magnitudes into the
    /// `Int32` range — and it must never trap doing it. A matched `.int` value passes straight
    /// through.
    @Test func intLiteralsMirrorTheByteWriterExactly() {
        #expect(ParamValues.mslLiteral(.int(7), as: .int) == "7")
        #expect(ParamValues.mslLiteral(.int(-7), as: .int) == "-7")
        #expect(ParamValues.mslLiteral(.float(2.7), as: .int) == "3")          // rounds, doesn't truncate
        #expect(ParamValues.mslLiteral(.float(-2.7), as: .int) == "-3")
        #expect(ParamValues.mslLiteral(.float(2.4), as: .int) == "2")
        #expect(ParamValues.mslLiteral(.float(.nan), as: .int) == "0")         // never traps
        #expect(ParamValues.mslLiteral(.float(.infinity), as: .int) == "\(Int32.max)")
        #expect(ParamValues.mslLiteral(.float(-.infinity), as: .int) == "\(Int32.min)")
        #expect(ParamValues.mslLiteral(.float(1e20), as: .int) == "\(Int32.max)")
        #expect(ParamValues.mslLiteral(.float(-1e20), as: .int) == "\(Int32.min)")
    }

    /// `ParamValues.int32(from:)` is the single rule both the literal path and `UniformImage`'s
    /// byte path use — assert it directly agrees with what the literal spells for the same edge
    /// cases, since that shared function is what makes the two paths incapable of disagreeing.
    @Test func int32FromMatchesTheLiteralItProduces() {
        for x: Float in [2.7, -2.7, .nan, .infinity, -.infinity, 1e20, -1e20, 0] {
            #expect("\(ParamValues.int32(from: x))" == ParamValues.mslLiteral(.float(x), as: .int))
        }
    }

    /// An `.enumCase`/`.asset` value under a vector slot (hand-edited or migrated) has no
    /// components at all. `UniformImage.write` no-ops and leaves the field zeroed; the literal
    /// path matches that all-zero result rather than inventing alpha-1 for a value it can't read.
    @Test func anEmptyComponentValueUnderAVectorSlotIsAllZero() {
        #expect(ParamValues.mslLiteral(.enumCase("x"), as: .float3) == "float3(0.0, 0.0, 0.0)")
        #expect(ParamValues.mslLiteral(.enumCase("x"), as: .float4) == "float4(0.0, 0.0, 0.0, 0.0)")
        #expect(ParamValues.mslLiteral(.enumCase("x"), as: .color) == "float4(0.0, 0.0, 0.0, 0.0)")
        #expect(ParamValues.mslLiteral(.asset(nil), as: .float2) == "float2(0.0, 0.0)")
    }
}
