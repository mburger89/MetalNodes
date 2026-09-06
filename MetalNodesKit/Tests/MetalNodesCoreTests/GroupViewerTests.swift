import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct GroupViewerTests {
    let reg = NodeRegistry.builtin

    /// Root: Float → Outer → Output; Outer: GroupInput.x → Inner → GroupOutput; Inner: GroupInput.x → Math(add) → GroupOutput.
    private func nested() -> (doc: ShaderDocument, outerInst: NodeID, innerInst: NodeID, math: NodeID, inner: GroupID) {
        var inner = GroupDefinition.make(name: "Inner")
        inner.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        inner.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        inner.graph.nodes[math.id] = math
        inner.graph.connect(SocketRef(inner.inputNode!, "x"), to: SocketRef(math.id, "a"))
        inner.graph.connect(SocketRef(math.id, "out"), to: SocketRef(inner.outputNode!, "out"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.inputs = inner.inputs; outer.outputs = inner.outputs
        let ii = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[ii.id] = ii
        outer.graph.connect(SocketRef(outer.inputNode!, "x"), to: SocketRef(ii.id, "x"))
        outer.graph.connect(SocketRef(ii.id, "out"), to: SocketRef(outer.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let f = NodeInstance(kind: .builtin("input.float")), io = NodeInstance(kind: .group(outer.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        for n in [f, io, out] { doc.root.nodes[n.id] = n }
        doc.root.connect(SocketRef(f.id, "out"), to: SocketRef(io.id, "x"))
        doc.root.connect(SocketRef(io.id, "out"), to: SocketRef(out.id, "color"))
        return (doc, io.id, ii.id, math.id, inner.id)
    }

    @Test func viewingInsideANestedDefinitionThroughTheDivedInstances() throws {
        let (doc, io, ii, math, _) = nested()
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [io, ii], registry: reg)
        #expect(s.target == .fragment && s.viewer == SocketRef(math, "out"))
        #expect(s.source.contains("_view("))                          // view variants exist
        #expect(s.source.contains("mn_g_Outer_") && s.source.contains("mn_g_Inner_"))
        #expect(s.source.contains("u.viewerMin"))
        #expect(s.source.contains(".value;"))                         // the root reads the view value
        #expect(!s.source.contains("return float4(v"))                // the Output node is not the terminal
    }

    @Test func viewingFromThePaletteUsesDeclaredDefaults() throws {
        let (doc, _, _, math, inner) = nested()
        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerDefinition: inner, registry: reg)
        #expect(s.source.contains("_view(in.uv, u.time, u.resolution, u.mouse, 1.0"))   // x's declared default as a literal
        // No per-instance slots: nothing in the root supplies a value. The definition's own
        // (shared) slots stay uniforms, so editing them still needs no recompile.
        let slots = s.layout.fields.compactMap(\.path)
        let perInstance = slots.filter { doc.root.nodes[$0.instancePath[0]] != nil }
        #expect(perInstance.isEmpty)
        #expect(slots == [ParamPath(node: math, param: "b")])   // Math's unwired `b`, shared by every instance
        #expect(s.source.contains("u.p0);"))                    // …and passed to the variant
        #expect(s.source.contains("u.viewerMin"))
    }

    /// Two instances of one definition, chained: only the one dived through becomes a view variant,
    /// so the sibling still feeds it its real value.
    @Test func onlyTheDivedThroughInstanceCallsTheVariant() throws {
        var inner = GroupDefinition.make(name: "Inner")
        inner.inputs = [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(1)))]
        inner.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let math = NodeInstance(kind: .builtin("math.math"), params: ["op": .enumCase("add")])
        inner.graph.nodes[math.id] = math
        inner.graph.connect(SocketRef(inner.inputNode!, "x"), to: SocketRef(math.id, "a"))
        inner.graph.connect(SocketRef(math.id, "out"), to: SocketRef(inner.outputNode!, "out"))
        var outer = GroupDefinition.make(name: "Outer")
        outer.inputs = inner.inputs; outer.outputs = inner.outputs
        let i1 = NodeInstance(kind: .group(inner.id)), i2 = NodeInstance(kind: .group(inner.id))
        outer.graph.nodes[i1.id] = i1; outer.graph.nodes[i2.id] = i2
        outer.graph.connect(SocketRef(outer.inputNode!, "x"), to: SocketRef(i1.id, "x"))
        outer.graph.connect(SocketRef(i1.id, "out"), to: SocketRef(i2.id, "x"))
        outer.graph.connect(SocketRef(i2.id, "out"), to: SocketRef(outer.outputNode!, "out"))
        var doc = ShaderDocument(); doc.definitions[inner.id] = inner; doc.definitions[outer.id] = outer
        let io = NodeInstance(kind: .group(outer.id)), out = NodeInstance(kind: .builtin("output.fragment"))
        doc.root.nodes[io.id] = io; doc.root.nodes[out.id] = out
        doc.root.connect(SocketRef(io.id, "out"), to: SocketRef(out.id, "color"))

        let s = try ShaderGenerator.generate(doc, viewer: SocketRef(math.id, "out"), viewerPath: [io.id, i2.id], registry: reg)
        let call = "mn_g_Inner_\(GroupCodegen.hex8(inner.id))"
        let outerVariant = s.source.components(separatedBy: "mn_g_Outer_\(GroupCodegen.hex8(outer.id))_view(float2 uv").last!
        #expect(outerVariant.contains("\(call)(uv,"))         // the upstream sibling keeps the normal function
        #expect(outerVariant.contains("\(call)_view(uv,"))    // the dived-through one yields the viewed value
    }

    @Test func aBrokenPathIsADiagnostic() {
        let (doc, io, _, math, _) = nested()
        #expect(throws: GenerationError.invalid([Diagnostic(.error, "The viewed instance no longer exists")])) {
            try ShaderGenerator.generate(doc, viewer: SocketRef(math, "out"), viewerPath: [io, NodeID()], registry: reg)
        }
    }
}
