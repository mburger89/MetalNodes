import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct ViewerCodegenTests {
    /// One constant node of `defID` plus a Fragment Output (unwired), viewer on the constant.
    private func oneNode(_ defID: String, socket: String = "out") -> (ShaderDocument, SocketRef) {
        let n = NodeInstance(kind: .builtin(defID)), out = NodeInstance(kind: .builtin("output.fragment"))
        var d = ShaderDocument(); d.root.nodes[n.id] = n; d.root.nodes[out.id] = out
        return (d, SocketRef(n.id, socket))
    }

    @Test func wrapStatementsPerType() {
        #expect(ViewerWrap.statement(variable: "v1", type: .float) ==
                "return float4(float3(saturate((v1 - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .int) ==
                "return float4(float3(saturate((float(v1) - u.viewerMin) / max(u.viewerMax - u.viewerMin, 1e-6))), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float2) == "return float4(v1, 0.0, 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float3) == "return float4(v1, 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .float4) == "return v1;")
        #expect(ViewerWrap.statement(variable: "v1", type: .color) == "return v1;")
        #expect(ViewerWrap.statement(variable: "v1", type: .bool) == "return float4(float3(v1 ? 1.0 : 0.0), 1.0);")
        #expect(ViewerWrap.statement(variable: "v1", type: .texture) == nil)
    }

    @Test func viewerProgramEndsAtTheViewedNodeAndHasTheRange() throws {
        let (doc, ref) = oneNode("input.float")
        let s = try ShaderGenerator.generate(doc, viewer: ref)
        #expect(s.viewer == ref)
        #expect(s.target == .fragment)
        #expect(s.layout.hasReserved("viewerMin") && s.layout.hasReserved("viewerMax"))
        #expect(s.source.contains("u.viewerMin"))
        #expect(!s.source.contains("/* unconnected */"))
        // The wrap line is owned by the viewed node.
        let wrapLine = s.source.components(separatedBy: "\n").firstIndex { $0.contains("return float4(float3(saturate") }! + 1
        #expect(s.lineMap.node(forLine: wrapLine) == ref.node)
        #expect(s.source.contains("return float4(float3(saturate((v0 - u.viewerMin)"))
    }

    @Test func fragmentProgramsHaveNoRangeUniforms() throws {
        let s = try ShaderGenerator.generate(ShaderDocument.sample())
        #expect(!s.layout.hasReserved("viewerMin"))
        #expect(s.viewer == nil)
    }

    @Test func viewerOnEveryConstantTypeGenerates() throws {
        for (def, socket) in [("input.float", "out"), ("input.color", "out"), ("input.uv", "uv"), ("vector.combine", "out")] {
            let (doc, ref) = oneNode(def, socket: socket)
            let s = try ShaderGenerator.generate(doc, viewer: ref)
            #expect(s.source.hasSuffix("}\n"), "\(def)")
            #expect(s.source.contains("return "), "\(def)")
        }
    }

    @Test func viewerUnderAStitchableTargetIsStillAFragmentProgram() throws {
        var (doc, ref) = oneNode("input.float")
        doc.settings.target = .stitchable(.colorEffect)
        let s = try ShaderGenerator.generate(doc, target: doc.settings.target, viewer: ref)
        #expect(s.target == .fragment)
        #expect(s.exportSource == nil)
        #expect(s.source.contains("fragment float4 shaderMain"))
    }

    @Test func viewerDCEDropsNodesNotUpstreamOfTheViewedOne() throws {
        let doc = ShaderDocument.sample()
        let noise = doc.root.nodes.values.first { $0.kind == .builtin("noise.value") }!
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(noise.id, "out"))
        #expect(s.source.contains("mn_valueNoise"))
        // Only the noise's `scale` slot survives: Speed and the tint colour feed nodes downstream of the viewer.
        #expect(s.layout.fields.filter { $0.path != nil }.count == 1)
    }

    @Test func aMissingViewerSocketIsADiagnostic() {
        let (doc, ref) = oneNode("input.float")
        let bad = SocketRef(ref.node, "nope")
        #expect(!GraphValidator.isValidViewer(bad, in: doc.root, registry: .builtin))
        #expect(throws: GenerationError.invalid([Diagnostic(.error, "The viewed socket no longer exists", node: ref.node, socket: "nope")])) {
            try ShaderGenerator.generate(doc, viewer: bad)
        }
    }
}
