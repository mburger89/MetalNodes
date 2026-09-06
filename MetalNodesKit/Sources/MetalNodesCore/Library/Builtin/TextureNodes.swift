import Foundation

extension BuiltinNodes {
    /// Texture sources (spec §21.2). Only `texture.sample` binds a slot; the other two are ordinary
    /// procedural colour nodes that happen to live under the same heading.
    static let texture: [NodeDef] = [
        // `{out.color}` substitutes to this node's SSA variable, so `{out.color}_s` is a distinct
        // identifier for the one sample both outputs read.
        NodeDef(id: "texture.sample", title: "Texture Sample", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color)),
                          SocketDecl(name: "alpha", type: .concrete(.float))],
                params: [ParamDecl(name: "asset", label: "Image", kind: .asset, defaultValue: .asset(nil), showsInBody: false)],
                requires: ["mn_sampler"],
                body: .template("""
                float4 {out.color}_s = {tex.sample};
                {out.color} = {out.color}_s;
                {out.alpha} = {out.color}_s.w;
                """)),
        NodeDef(id: "texture.gradient", title: "Gradient", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                params: [ParamDecl(name: "shape", kind: .enumeration(["linear", "radial"]), defaultValue: .enumCase("linear")),
                         ParamDecl(name: "angle", kind: .value(.float, range: 0...360), defaultValue: .float(0)),
                         ParamDecl(name: "colorA", label: "Color A", kind: .value(.color, range: 0...1),
                                   defaultValue: .float4(.init(0, 0, 0, 1)), showsInBody: false),
                         ParamDecl(name: "colorB", label: "Color B", kind: .value(.color, range: 0...1),
                                   defaultValue: .float4(.init(1, 1, 1, 1)), showsInBody: false)],
                requires: ["mn_gradient"],
                body: .variants(param: "shape", [
                    "linear": "{out.color} = mix({param.colorA}, {param.colorB}, mn_gradient({in.uv}, {param.angle}));",
                    "radial": "{out.color} = mix({param.colorA}, {param.colorB}, saturate(length({in.uv} - 0.5) * 2.0));",
                ])),
        NodeDef(id: "texture.checker", title: "Checker", category: .input,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv)],
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                params: [ParamDecl(name: "scale", kind: .value(.float, range: 1...64), defaultValue: .float(8)),
                         ParamDecl(name: "colorA", label: "Color A", kind: .value(.color, range: 0...1),
                                   defaultValue: .float4(.init(0, 0, 0, 1)), showsInBody: false),
                         ParamDecl(name: "colorB", label: "Color B", kind: .value(.color, range: 0...1),
                                   defaultValue: .float4(.init(1, 1, 1, 1)), showsInBody: false)],
                requires: ["mn_checker"],
                body: .template("{out.color} = mix({param.colorA}, {param.colorB}, mn_checker({in.uv}, {param.scale}));")),
    ]
}
