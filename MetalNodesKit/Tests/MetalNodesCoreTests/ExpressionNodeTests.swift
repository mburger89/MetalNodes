import Testing
import Foundation
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
        // text around it survives verbatim. Asserting the whole statement (not just a fragment)
        // is what catches a stray unsubstituted placeholder landing anywhere else in the line.
        #expect(!s.contains("/* ?"))   // no placeholder ever reaches generated source
        #expect(s.contains("v0 = float4(u.p0, 0.0, 0.0, 1.0);"))
        #expect(!s.contains("uvx"))   // substituted, not passed through
    }

    @Test func anExpressionEmitsNoFunction() throws {
        let s = try ShaderGenerator.generate(document("a * 2.0")).source
        #expect(!s.contains("/* ?"))
        #expect(!s.contains("mn_g_"))
    }

    /// The specific defect Deviation 1 fixed: with the registry def's (empty) sockets driving
    /// `declareOutputs`, the Expression's `out` never became an SSA variable, so a wire into it
    /// silently failed and the terminal fell back to its own unwired default instead. Assert the
    /// full path: the expression's own statement *and* that the terminal's `return` actually
    /// names that same variable, not a marker or a default.
    @Test func theTerminalReadsTheExpressionsOutputVariable() throws {
        let s = try ShaderGenerator.generate(document("a + 1.0")).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = u.p0 + 1.0;"))
        #expect(s.contains("return v0;"))
    }

    /// Nothing else in this suite wires a value into an Expression's own input, so the wired
    /// branch of `inputExpressions` — and the `ConversionRules.convert(from:to:)!` force-unwrap it
    /// runs under Expression's per-socket `T0…Tn` generics — was previously untested.
    @Test func aWiredInputConvertsAndSubstitutes() throws {
        var doc = ShaderDocument()
        var g = Graph()
        let uv = NodeInstance(kind: .builtin("input.uv"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("a.x"), "type": .enumCase("float")])
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[uv.id] = uv
        g.nodes[expr.id] = expr
        g.nodes[terminal.id] = terminal
        g.inputs[SocketRef(expr.id, "a")] = SocketRef(uv.id, "uv")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        doc.root = g
        let s = try ShaderGenerator.generate(doc).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = in.uv;"))
        #expect(s.contains("v1 = v0.x;"))
    }

    /// The Critical this round fixed: Swift `Regex`'s `\b` is a Unicode word boundary, and `.`
    /// between letters is *not* a break there, so `\bcol\b` never matches inside `col.rgb` at
    /// all — the identifier silently passed through unsubstituted and `col` reached generated
    /// source as an undefined name. `MSLScanner.rewritingIdentifiers` must both substitute `col`
    /// and leave `.rgb` untouched.
    @Test func aSwizzledIdentifierIsSubstitutedWithoutTouchingTheMember() throws {
        let s = try ShaderGenerator.generate(document("float4(col.rgb, 1.0)", type: "color")).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = float4(u.p0.rgb, 1.0);"))
    }

    /// The mirror bug a naive `wordBoundaryKind(.simple)` regex would reintroduce: `a` must be
    /// substituted where it is a free identifier, but the `.a` member access on `b` must not be
    /// touched just because `a` is also a socket name elsewhere in the formula.
    @Test func anIdentifierThatAlsoAppearsAsAMemberKeepsTheMemberUntouched() throws {
        let s = try ShaderGenerator.generate(document("a + b.a")).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = u.p0 + u.p1.a;"))
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
        #expect(!s.contains("/* ?"))
        #expect(s.contains("* 2.0"))
        #expect(s.contains("* 3.0"))
    }

    @Test func generationIsDeterministic() throws {
        let doc = document("a + b")
        let s = try ShaderGenerator.generate(doc).source
        #expect(!s.contains("/* ?"))
        #expect(s == (try ShaderGenerator.generate(doc).source))
    }

    /// `a` is a substring of `saturate`; whole-token replacement must leave the call untouched.
    @Test func anIdentifierThatIsASubstringOfABuiltinIsNotCorrupted() throws {
        let s = try ShaderGenerator.generate(document("saturate(a)")).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = saturate(u.p0);"))
    }

    /// A formula of only whitespace passes the old `isEmpty` guard and would previously emit
    /// `v0 =   ;` — invalid MSL with nothing between `=` and `;`.
    @Test func aWhitespaceOnlyFormulaEmitsAValidDefault() throws {
        let s = try ShaderGenerator.generate(document("   ")).source
        #expect(!s.contains("/* ?"))
        #expect(s.contains("v0 = 0.0;"))
    }

    /// The highest-value regression for the swizzle Critical: an Expression with a real swizzle,
    /// run through the actual Metal compiler. `xcrun metal` is not always installed; skip
    /// silently when it is not (same pattern as `FragmentExportTests`).
    @Test func exportedExpressionMetalCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        // `col` is wired to a real float2 source so `.xy` swizzles a vector, not the scalar
        // default an unwired socket would fall back to — the point is to compile a genuine
        // swizzle, not merely to survive one that never runs through `metal`.
        var d = ShaderDocument()
        var g = Graph()
        let uv = NodeInstance(kind: .builtin("input.uv"), position: .zero)
        let expr = NodeInstance(kind: .builtin("utility.expression"), position: .zero,
                                params: ["formula": .text("float4(col.xy, 0.0, 1.0)"), "type": .enumCase("color")])
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        g.nodes[uv.id] = uv
        g.nodes[expr.id] = expr
        g.nodes[terminal.id] = terminal
        g.inputs[SocketRef(expr.id, "col")] = SocketRef(uv.id, "uv")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(expr.id, "out")
        d.root = g
        d.settings.exportName = "exprswizzle"
        let files = try ShaderExport.files(for: d, registry: .builtin)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-exprexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(files[0].name)
        try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
        try metal.run(); metal.waitUntilExit()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(metal.terminationStatus == 0, "\(log)")
    }
}
