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

    static let noise: [NodeDef] = [
        NodeDef(id: "noise.value", title: "Value Noise", category: .noise,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "scale", type: .concrete(.float), default: .value(.float(4)), range: 0.1...32)],
                outputs: [SocketDecl(name: "out", label: "Value", type: .concrete(.float))],
                requires: ["valueNoise"],
                body: .template("{out.out} = mn_valueNoise({in.uv} * {in.scale});")),
    ]

    static let output: [NodeDef] = [
        NodeDef(id: "output.fragment", title: "Fragment Output", category: .output,
                inputs: [SocketDecl(name: "color", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))))],
                body: .template("return {in.color};")),
    ]

    public static let all: [NodeDef] = input + math + vector + noise + output
}
