import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct StitchableCodegenTests {
    private func smallDocument(_ kind: StitchableKind, name: String = "ripple") -> ShaderDocument {
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
        d.settings.target = .stitchable(kind); d.settings.exportName = name
        return d
    }

    @Test func namesAreSanitisedToIdentifiers() {
        #expect(StitchableCodegen.sanitizedName("ripple") == "ripple")
        #expect(StitchableCodegen.sanitizedName("My Cool Shader!") == "My_Cool_Shader_")
        #expect(StitchableCodegen.sanitizedName("9lives") == "_9lives")
        #expect(StitchableCodegen.sanitizedName("   ") == "metalNodesShader")
        #expect(StitchableCodegen.sanitizedName("") == "metalNodesShader")
        // A name that lands on a Swift or MSL keyword would not compile in either file.
        #expect(StitchableCodegen.sanitizedName("default") == "default_")
        #expect(StitchableCodegen.sanitizedName("fragment") == "fragment_")
        #expect(StitchableCodegen.sanitizedName("Default") == "Default")
    }

    @Test func argumentsAreMouseThenSlotsInLayoutOrderWithScalarsAsFloat() {
        let a = NodeID(), b = NodeID()
        let layout = UniformLayoutBuilder.build([(ParamPath(node: a, param: "i"), .int), (ParamPath(node: b, param: "v"), .float3), (ParamPath(node: a, param: "f"), .bool), (ParamPath(node: b, param: "c"), .color)])
        let args = StitchableCodegen.arguments(layout: layout)
        #expect(args.map(\.name) == ["mouse", "p0", "p1", "p2", "p3"])  // float3/color sort first (alignment 16)
        // `.color(_:)` arrives as a premultiplied half4; int/bool have no Shader.Argument and travel as float.
        #expect(args.map(\.mslType) == ["float2", "float3", "half4", "float", "float"])
        #expect(args[0].field == nil)
        #expect(args[1].field?.type == .float3)
        #expect(args[2].field?.type == .color)
    }

    @Test func colorEffectExportGolden() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        let expected = """
        #include <metal_stdlib>
        using namespace metal;

        [[stitchable]] half4 ripple(float2 position, half4 currentColor, float2 size, float time, float2 mouse, float p0) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            float2 v0;
            v0 = uv;
            float v1;
            float v2;
            float v3;
            v1 = float3(v0, 0.0).x;
            v2 = float3(v0, 0.0).y;
            v3 = float3(v0, 0.0).z;
            float3 v4;
            v4 = float3(v1, v2, p0);
            return half4(float4(v4, 1.0));
        }

        """
        #expect(s.exportSource == expected)
        #expect(s.functionName == "ripple")
        #expect(s.target == .stitchable(.colorEffect))
    }

    @Test func previewWrapsTheFunctionAndReadsUniforms() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        #expect(!s.source.contains("[[stitchable]]"))
        #expect(s.source.contains("half4 ripple(float2 position, half4 currentColor, float2 size, float time, float2 mouse, float p0)"))
        #expect(s.source.contains("float2 position = float2(in.uv.x, 1.0 - in.uv.y) * u.resolution;"))
        #expect(s.source.contains("half4 c = ripple(position, half4(0.0), u.resolution, u.time, u.mouse, u.p0);"))
        #expect(s.source.contains("return float4(c);"))
        #expect(s.source.contains("struct Uniforms"))
        #expect(s.fragmentFunctionName == "shaderMain")
    }

    @Test func distortionReturnsASourcePositionAndPreviewsTheField() throws {
        let s = try ShaderGenerator.generate(smallDocument(.distortionEffect), target: .stitchable(.distortionEffect))
        #expect(s.exportSource!.contains("[[stitchable]] float2 ripple(float2 position, float2 size, float time, float2 mouse, float p0)"))
        #expect(s.exportSource!.contains("return float2(float4(v4, 1.0).x, 1.0 - float4(v4, 1.0).y) * size;"))
        #expect(s.source.contains("float2 c = ripple(position, u.resolution, u.time, u.mouse, u.p0);"))
        #expect(s.source.contains("return float4(c / u.resolution, 0.0, 1.0);"))
    }

    @Test func layerEffectExportHasTheLayerAndThePreviewDoesNot() throws {
        let s = try ShaderGenerator.generate(smallDocument(.layerEffect), target: .stitchable(.layerEffect))
        #expect(s.exportSource!.contains("#include <SwiftUI/SwiftUI_Metal.h>"))
        #expect(s.exportSource!.contains("[[stitchable]] half4 ripple(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse, float p0)"))
        #expect(!s.source.contains("SwiftUI"))
        #expect(s.source.contains("half4 ripple(float2 position, float2 size, float time, float2 mouse, float p0)"))
    }

    @Test func unwiredOutputColorFallsBackToItsUniformDefault() throws {
        let out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[out.id] = out
        let s = try ShaderGenerator.generate(d, target: .stitchable(.colorEffect))
        // The Output's `color` input is a `.color` slot, so it arrives as SwiftUI's premultiplied half4.
        #expect(s.exportSource!.contains("half4 p0)"))
        #expect(s.exportSource!.contains("return half4(float4(p0));"))
        // The preview keeps it in the float4 `Uniforms` slot and narrows at the call.
        #expect(s.source.contains("half4(u.p0)"))
    }

    @Test func lineMapCoversTheStitchableBody() throws {
        let s = try ShaderGenerator.generate(smallDocument(.colorEffect), target: .stitchable(.colorEffect))
        let line = s.source.components(separatedBy: "\n").firstIndex { $0.contains("v4 = float3(v1, v2, p0);") }! + 1
        #expect(s.lineMap.node(forLine: line) != nil)
    }
}
