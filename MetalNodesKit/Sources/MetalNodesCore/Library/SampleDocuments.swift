import Foundation
import CoreGraphics

public extension ShaderDocument {
    /// The graph the app opens with: UV-driven gradient, animated blue channel,
    /// value-noise mixed with a tint. Exercises conversions, generics, variants,
    /// stdlib `requires`, and three uniform slots of different alignment.
    static func sample() -> ShaderDocument {
        func node(_ id: String, _ x: CGFloat, _ y: CGFloat, _ params: [ParamID: ParamValue] = [:]) -> NodeInstance {
            NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: y), params: params)
        }
        let uv     = node("input.uv", 0, 0)
        let time   = node("input.time", 0, 160)
        let speed  = node("input.float", 0, 280, ["value": .float(0.25)])
        let mul    = node("math.math", 220, 200, ["op": .enumCase("multiply")])
        let sine   = node("math.math", 440, 200, ["op": .enumCase("sine")])
        let sep    = node("vector.separate", 220, 0)
        let comb   = node("vector.combine", 660, 60)
        let noise  = node("noise.value", 440, 360, ["scale": .float(6)])
        let tint   = node("input.color", 660, 360, ["value": .float4(.init(0.74, 0.58, 0.98, 1))])
        let mixN   = node("math.mix", 880, 200)
        let out    = node("output.fragment", 1100, 200)

        var g = Graph()
        for n in [uv, time, speed, mul, sine, sep, comb, noise, tint, mixN, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(time.id, "time"),  to: SocketRef(mul.id, "a"))
        g.connect(SocketRef(speed.id, "out"),  to: SocketRef(mul.id, "b"))
        g.connect(SocketRef(mul.id, "out"),    to: SocketRef(sine.id, "a"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(sep.id, "v"))       // float2 → float3
        g.connect(SocketRef(sep.id, "x"),      to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"),      to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(sine.id, "out"),   to: SocketRef(comb.id, "z"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(noise.id, "uv"))
        g.connect(SocketRef(comb.id, "out"),   to: SocketRef(mixN.id, "a"))      // T = float3
        g.connect(SocketRef(tint.id, "out"),   to: SocketRef(mixN.id, "b"))      // color → float3
        g.connect(SocketRef(noise.id, "out"),  to: SocketRef(mixN.id, "t"))
        g.connect(SocketRef(mixN.id, "out"),   to: SocketRef(out.id, "color"))   // float3 → color

        var doc = ShaderDocument()
        doc.root = g
        return doc
    }

    /// A RealityKit material demonstrating the target (spec §23): Value Noise varies Roughness
    /// across the surface, a Color feeds Base Color, and Time drives a small bob through the
    /// geometry stage — Math(multiply)/Math(sine) scaled down and fed into one axis of a Combine
    /// XYZ, so Position Offset moves the mesh without it flying apart.
    static func realityKitMaterial() -> ShaderDocument {
        func node(_ id: String, _ x: CGFloat, _ y: CGFloat, _ params: [ParamID: ParamValue] = [:]) -> NodeInstance {
            NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: y), params: params)
        }
        let time   = node("input.time", 0, 0)
        let speed  = node("input.float", 0, 120, ["value": .float(0.6)])
        let amp    = node("input.float", 0, 240, ["value": .float(0.06)])
        let mul    = node("math.math", 220, 60, ["op": .enumCase("multiply")])
        let sine   = node("math.math", 440, 60, ["op": .enumCase("sine")])
        let noise  = node("noise.value", 440, 300, ["scale": .float(6)])
        let mul2   = node("math.math", 660, 60, ["op": .enumCase("multiply")])
        let color  = node("input.color", 660, 300, ["value": .float4(.init(0.85, 0.55, 0.25, 1))])
        let combine = node("vector.combine", 880, 60)
        let out    = node("output.material", 1100, 150)

        var g = Graph()
        for n in [time, speed, amp, mul, sine, noise, mul2, color, combine, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(time.id, "time"),    to: SocketRef(mul.id, "a"))
        g.connect(SocketRef(speed.id, "out"),    to: SocketRef(mul.id, "b"))
        g.connect(SocketRef(mul.id, "out"),      to: SocketRef(sine.id, "a"))
        g.connect(SocketRef(sine.id, "out"),     to: SocketRef(mul2.id, "a"))
        g.connect(SocketRef(amp.id, "out"),      to: SocketRef(mul2.id, "b"))
        g.connect(SocketRef(mul2.id, "out"),     to: SocketRef(combine.id, "y"))
        g.connect(SocketRef(noise.id, "out"),    to: SocketRef(out.id, "roughness"))
        g.connect(SocketRef(color.id, "out"),    to: SocketRef(out.id, "baseColor"))
        g.connect(SocketRef(combine.id, "out"),  to: SocketRef(out.id, "positionOffset"))

        var doc = ShaderDocument()
        doc.root = g
        doc.settings.target = .realityKit
        doc.settings.lightingModel = .lit
        return doc
    }

    /// A RealityKit material whose roughness comes from an Expression and whose base colour goes
    /// through a Custom MSL definition — the two M8 node kinds (spec §24.2, §24.3) in one
    /// document, so the in-app checklist and the compile tests both have something real to open.
    ///
    /// The Custom MSL body reads `in_c`, not `c`: a definition's inputs reach the emitted function
    /// only as `in_<name>` (`GroupCodegen.systemParams`), and `c` alone is the shape that fails to
    /// compile with `use of undeclared identifier`. The formula names `uv` and no other free
    /// identifier — `clamp` is in `MSLScanner.reservedNames` and `.x` is a member access — so the
    /// Expression node carries exactly one input socket, called `uv`.
    static func customCodeSample() -> ShaderDocument {
        func node(_ id: String, _ x: CGFloat, _ y: CGFloat, _ params: [ParamID: ParamValue] = [:]) -> NodeInstance {
            NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: y), params: params)
        }

        var tint = GroupDefinition(name: "Tint")
        tint.inputs = [SocketDecl(name: "c", label: "Color", type: .concrete(.float3),
                                  default: .value(.float3(.init(1, 1, 1))))]
        tint.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float3))]
        tint.body = .msl("out = in_c * float3(1.0, 0.85, 0.7);")

        let base   = node("input.color", 0, 0, ["value": .float4(.init(0.2, 0.5, 0.9, 1))])
        let tinted = NodeInstance(kind: .group(tint.id), position: CGPoint(x: 280, y: 0))
        // Normalized, spelled out: `aspect` reads `{sys.resolution}`, which is `readable: false`
        // under both material stages, so that variant is refused on this target (spec §24.10).
        let uv     = node("input.uv", 0, 240, ["mode": .enumCase("normalized")])
        let expr   = node(ExpressionNode.id, 280, 240, [
            ExpressionNode.formulaParam: .text("clamp(uv.x, 0.05, 0.95)"),
            ExpressionNode.outputTypeParam: .enumCase("float"),
        ])
        let out    = node("output.material", 560, 100)

        var g = Graph()
        for n in [base, tinted, uv, expr, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(base.id, "out"),   to: SocketRef(tinted.id, "c"))    // color → float3
        g.connect(SocketRef(tinted.id, "out"), to: SocketRef(out.id, "baseColor"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(expr.id, "uv"))
        g.connect(SocketRef(expr.id, "out"),   to: SocketRef(out.id, "roughness"))

        var doc = ShaderDocument()
        doc.root = g
        doc.definitions[tint.id] = tint
        doc.settings.target = .realityKit
        doc.settings.lightingModel = .lit
        doc.settings.exportName = "customCodeSample"
        return doc
    }

    /// `sample()` with its Time → Multiply → Sine chain folded into a "Wobble" definition
    /// (spec §20.4). Covers a wired exposed input (`t`), a slot shared by the definition
    /// (the Float's value, inside), and the root's own per-instance slots.
    static func sampleWithGroup() -> ShaderDocument {
        func node(_ id: String, _ x: CGFloat, _ y: CGFloat, _ params: [ParamID: ParamValue] = [:]) -> NodeInstance {
            NodeInstance(kind: .builtin(id), position: CGPoint(x: x, y: y), params: params)
        }

        var wobble = GroupDefinition.make(name: "Wobble")
        wobble.inputs = [SocketDecl(name: "t", type: .concrete(.float), default: .value(.float(0)), range: -10...10)]
        wobble.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let speed = node("input.float", 220, 160, ["value": .float(0.25)])
        let mul = node("math.math", 220, 0, ["op": .enumCase("multiply")])
        let sine = node("math.math", 400, 0, ["op": .enumCase("sine")])
        for n in [speed, mul, sine] { wobble.graph.nodes[n.id] = n }
        wobble.graph.connect(SocketRef(wobble.inputNode!, "t"), to: SocketRef(mul.id, "a"))
        wobble.graph.connect(SocketRef(speed.id, "out"), to: SocketRef(mul.id, "b"))
        wobble.graph.connect(SocketRef(mul.id, "out"), to: SocketRef(sine.id, "a"))
        wobble.graph.connect(SocketRef(sine.id, "out"), to: SocketRef(wobble.outputNode!, "out"))

        let uv    = node("input.uv", 0, 0)
        let time  = node("input.time", 0, 160)
        let inst  = NodeInstance(kind: .group(wobble.id), position: CGPoint(x: 220, y: 200))
        let sep   = node("vector.separate", 220, 0)
        let comb  = node("vector.combine", 660, 60)
        let noise = node("noise.value", 440, 360, ["scale": .float(6)])
        let tint  = node("input.color", 660, 360, ["value": .float4(.init(0.74, 0.58, 0.98, 1))])
        let mixN  = node("math.mix", 880, 200)
        let out   = node("output.fragment", 1100, 200)

        var g = Graph()
        for n in [uv, time, inst, sep, comb, noise, tint, mixN, out] { g.nodes[n.id] = n }
        g.connect(SocketRef(time.id, "time"),  to: SocketRef(inst.id, "t"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(sep.id, "v"))
        g.connect(SocketRef(sep.id, "x"),      to: SocketRef(comb.id, "x"))
        g.connect(SocketRef(sep.id, "y"),      to: SocketRef(comb.id, "y"))
        g.connect(SocketRef(inst.id, "out"),   to: SocketRef(comb.id, "z"))
        g.connect(SocketRef(uv.id, "uv"),      to: SocketRef(noise.id, "uv"))
        g.connect(SocketRef(comb.id, "out"),   to: SocketRef(mixN.id, "a"))
        g.connect(SocketRef(tint.id, "out"),   to: SocketRef(mixN.id, "b"))
        g.connect(SocketRef(noise.id, "out"),  to: SocketRef(mixN.id, "t"))
        g.connect(SocketRef(mixN.id, "out"),   to: SocketRef(out.id, "color"))

        var doc = ShaderDocument()
        doc.root = g
        doc.definitions[wobble.id] = wobble
        return doc
    }
}
