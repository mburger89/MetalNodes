import Testing
@testable import MetalNodesCore

@Suite struct ExpressionNodeTests {
    private func instance(_ formula: String, type: String = "float") -> NodeInstance {
        NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                     params: ["formula": .text(formula), "type": .enumCase(type)])
    }

    private func shape(_ formula: String, type: String = "float") -> NodeShape {
        var doc = ShaderDocument()
        let n = instance(formula, type: type)
        doc.root.nodes[n.id] = n
        return doc.shape(of: n, in: .root, registry: .builtin)!
    }

    @Test func theNodeIsRegistered() {
        let d = NodeRegistry.builtin["utility.expression"]
        #expect(d != nil)
        #expect(d?.category == .utility)
        #expect(d?.param(named: "formula") != nil)
        #expect(d?.param(named: "type") != nil)
    }

    @Test func socketsComeFromTheFormula() {
        #expect(shape("sin(a * 6.28) * b").inputs.map(\.name) == ["a", "b"])
        #expect(shape("b + a").inputs.map(\.name) == ["b", "a"])
        #expect(shape("1.0").inputs.isEmpty)
    }

    /// Every inferred input gets its own generic, so a float2 and a float can be wired into the
    /// same expression (spec §24.2). One shared T would reject that.
    @Test func eachInputGetsItsOwnGeneric() {
        let s = shape("a + b")
        #expect(s.inputs.map(\.type) == [.generic("T0"), .generic("T1")])
        #expect(s.generics["T0"] != nil)
        #expect(s.generics["T1"] != nil)
        #expect(s.generics.count == 2)
    }

    @Test func theOutputTypeComesFromTheTypeParam() {
        #expect(shape("a", type: "float").outputs.first?.type == .concrete(.float))
        #expect(shape("a", type: "float3").outputs.first?.type == .concrete(.float3))
        #expect(shape("a", type: "color").outputs.first?.type == .concrete(.color))
        #expect(shape("a").outputs.map(\.name) == ["out"])
    }

    /// The shape must not change when the formula does not, or the canvas would rewire on every
    /// keystroke; and it must change when it does, or a new socket never appears.
    @Test func theShapeTracksTheFormula() {
        #expect(shape("a").inputs.map(\.name) == ["a"])
        #expect(shape("a + b").inputs.map(\.name) == ["a", "b"])
        #expect(shape("a").inputs.map(\.name) == ["a"])
    }

    @Test func anEmptyOrMissingFormulaYieldsNoInputs() {
        #expect(shape("").inputs.isEmpty)
        var doc = ShaderDocument()
        let bare = NodeInstance(kind: .builtin("utility.expression"), position: .zero)
        doc.root.nodes[bare.id] = bare
        #expect(doc.shape(of: bare, in: .root, registry: .builtin)?.inputs.isEmpty == true)
    }
}
