import Foundation

public extension NodeRegistry {
    /// The M1 library. Every entry is data; see spec §8 and §13.
    static let builtin: NodeRegistry = {
        do { return try NodeRegistry(BuiltinNodes.all) }
        catch { fatalError("Builtin node library is invalid: \(error)") }
    }()
}

public enum BuiltinNodes {
    static let anyFloat: [SocketType] = [.float, .float2, .float3, .float4]
    static let anyVector: [SocketType] = [.float2, .float3, .float4]

    public static let all: [NodeDef] = [
        // MARK: Input
        NodeDef(id: "input.uv", title: "UV", category: .input,
                outputs: [SocketDecl(name: "uv", type: .concrete(.float2))],
                params: [ParamDecl(name: "mode", kind: .enumeration(["normalized", "aspect"]), defaultValue: .enumCase("normalized"))],
                body: .variants(param: "mode", [
                    "normalized": "{out.uv} = in.uv;",
                    "aspect": "{out.uv} = (in.uv - 0.5) * (u.resolution / u.resolution.y);",
                ])),
        NodeDef(id: "input.time", title: "Time", category: .input,
                outputs: [SocketDecl(name: "time", type: .concrete(.float))],
                body: .template("{out.time} = u.time;")),
        NodeDef(id: "input.resolution", title: "Resolution", category: .input,
                outputs: [SocketDecl(name: "resolution", type: .concrete(.float2))],
                body: .template("{out.resolution} = u.resolution;")),
        NodeDef(id: "input.float", title: "Float", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                params: [ParamDecl(name: "value", kind: .value(.float, range: -10...10), defaultValue: .float(1))],
                body: .template("{out.out} = {param.value};")),
        NodeDef(id: "input.color", title: "Color", category: .input,
                outputs: [SocketDecl(name: "out", type: .concrete(.color))],
                params: [ParamDecl(name: "value", kind: .value(.color, range: 0...1), defaultValue: .float4(.init(1, 1, 1, 1)))],
                body: .template("{out.out} = {param.value};")),

        // MARK: Math
        NodeDef(id: "math.math", title: "Math", category: .math,
                inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                         SocketDecl(name: "b", type: .generic("T"), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                params: [ParamDecl(name: "op", label: "Operation",
                                   kind: .enumeration(["add", "subtract", "multiply", "divide", "power", "modulo",
                                                       "minimum", "maximum", "absolute", "floor", "fract", "sqrt",
                                                       "sine", "cosine", "tangent"]),
                                   defaultValue: .enumCase("add"))],
                generics: ["T": anyFloat],
                body: .variants(param: "op", [
                    "add":      "{out.out} = {in.a} + {in.b};",
                    "subtract": "{out.out} = {in.a} - {in.b};",
                    "multiply": "{out.out} = {in.a} * {in.b};",
                    "divide":   "{out.out} = {in.a} / {in.b};",
                    "power":    "{out.out} = pow({in.a}, {in.b});",
                    "modulo":   "{out.out} = fmod({in.a}, {in.b});",
                    "minimum":  "{out.out} = min({in.a}, {in.b});",
                    "maximum":  "{out.out} = max({in.a}, {in.b});",
                    "absolute": "{out.out} = abs({in.a});",
                    "floor":    "{out.out} = floor({in.a});",
                    "fract":    "{out.out} = fract({in.a});",
                    "sqrt":     "{out.out} = sqrt({in.a});",
                    "sine":     "{out.out} = sin({in.a});",
                    "cosine":   "{out.out} = cos({in.a});",
                    "tangent":  "{out.out} = tan({in.a});",
                ])),
        NodeDef(id: "math.mix", title: "Mix", category: .math,
                inputs: [SocketDecl(name: "a", type: .generic("T"), default: .value(.float(0))),
                         SocketDecl(name: "b", type: .generic("T"), default: .value(.float(1))),
                         SocketDecl(name: "t", label: "Factor", type: .concrete(.float), default: .value(.float(0.5)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = mix({in.a}, {in.b}, {in.t});")),
        NodeDef(id: "math.smoothstep", title: "Smoothstep", category: .math,
                inputs: [SocketDecl(name: "edge0", label: "Edge 0", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "edge1", label: "Edge 1", type: .concrete(.float), default: .value(.float(1))),
                         SocketDecl(name: "x", type: .generic("T"), default: .value(.float(0.5)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyFloat],
                body: .template("{out.out} = smoothstep({type.T}({in.edge0}), {type.T}({in.edge1}), {in.x});")),

        // MARK: Vector
        NodeDef(id: "vector.combine", title: "Combine XYZ", category: .vector,
                inputs: [SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "y", type: .concrete(.float), default: .value(.float(0))),
                         SocketDecl(name: "z", type: .concrete(.float), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .concrete(.float3))],
                body: .template("{out.out} = float3({in.x}, {in.y}, {in.z});")),
        NodeDef(id: "vector.separate", title: "Separate XYZ", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .concrete(.float3), default: .value(.float3(.init(0, 0, 0))))],
                outputs: [SocketDecl(name: "x", type: .concrete(.float)),
                          SocketDecl(name: "y", type: .concrete(.float)),
                          SocketDecl(name: "z", type: .concrete(.float))],
                body: .template("{out.x} = {in.v}.x;\n{out.y} = {in.v}.y;\n{out.z} = {in.v}.z;")),
        NodeDef(id: "vector.length", title: "Length", category: .vector,
                inputs: [SocketDecl(name: "v", label: "Vector", type: .generic("T"), default: .value(.float2(.init(0, 0))))],
                outputs: [SocketDecl(name: "out", type: .concrete(.float))],
                generics: ["T": anyVector],
                body: .template("{out.out} = length({in.v});")),

        // MARK: Noise
        NodeDef(id: "noise.value", title: "Value Noise", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)))],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                requires: ["valueNoise"],
                body: .template("{out.out} = mn_valueNoise({in.uv} * {in.scale});")),

        // MARK: Output
        NodeDef(id: "output.fragment", title: "Fragment Output", category: .output,
                inputs: [SocketDecl(name: "color", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))))],
                body: .template("return {in.color};")),
    ]
}
