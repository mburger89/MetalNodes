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
