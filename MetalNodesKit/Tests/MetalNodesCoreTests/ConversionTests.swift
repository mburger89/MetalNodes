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
