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

@Suite struct ExpressionEmissionTests {
    /// A document with one Expression wired into the fragment terminal.
    private func document(_ formula: String, type: String = "color") -> ShaderDocument {
        var doc = ShaderDocument()
        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text(formula), "type": .enumCase(type)])
        g.nodes[terminal.id] = terminal
        g.nodes[expr.id] = expr
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        return doc
    }

    @Test func theFormulaBecomesOneStatement() throws {
        let s = try ShaderGenerator.generate(document("float4(uvx, 0.0, 0.0, 1.0)")).source
        // The identifier is substituted for whatever the caller wired or defaulted; the literal
        // text around it survives verbatim.
        #expect(s.contains("float4("))
        #expect(s.contains(", 0.0, 0.0, 1.0)"))
        #expect(!s.contains("uvx"))   // substituted, not passed through
    }

    @Test func anExpressionEmitsNoFunction() throws {
        let s = try ShaderGenerator.generate(document("a * 2.0")).source
        #expect(!s.contains("mn_g_"))
    }

    /// Two Expression nodes are independent — the point of instance data (spec §24.2). Both feed
    /// a Mix so both stay reachable from the terminal (DCE would otherwise drop an orphaned node
    /// before it ever reaches the emitter).
    @Test func twoExpressionsEmitTwoStatements() throws {
        var doc = document("a * 2.0")
        let first = doc.root.nodes.values.first { $0.kind == .builtin("utility.expression") }!
        let second = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                  params: ["formula": .text("a * 3.0"), "type": .enumCase("float")])
        doc.root.nodes[second.id] = second
        let mix = NodeInstance(kind: .builtin("math.mix"), position: .zero)
        doc.root.nodes[mix.id] = mix
        doc.root.inputs[SocketRef(mix.id, "a")] = SocketRef(first.id, "out")
        doc.root.inputs[SocketRef(mix.id, "b")] = SocketRef(second.id, "out")
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.fragment") }!
        doc.root.inputs[SocketRef(terminal.id, "color")] = SocketRef(mix.id, "out")
        let s = try ShaderGenerator.generate(doc).source
        #expect(s.contains("* 2.0"))
        #expect(s.contains("* 3.0"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document("a + b")
        #expect(try ShaderGenerator.generate(doc).source == (try ShaderGenerator.generate(doc).source))
    }

    /// `a` is a substring of `saturate`; whole-token replacement must leave the call untouched.
    @Test func anIdentifierThatIsASubstringOfABuiltinIsNotCorrupted() throws {
        let s = try ShaderGenerator.generate(document("saturate(a)")).source
        #expect(s.contains("saturate("))
        #expect(!s.contains("s{in.a}turate"))
    }
}
