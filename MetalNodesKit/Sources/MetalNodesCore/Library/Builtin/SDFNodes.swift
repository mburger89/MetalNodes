import Foundation

extension BuiltinNodes {
    static let sdf: [NodeDef] = [
        NodeDef(id: "sdf.circle", title: "Circle", category: .sdf,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "center", type: .concrete(.float2), default: .value(.float2(.init(0.5, 0.5))), range: -1...2),
                         SocketDecl(name: "radius", type: .concrete(.float), default: .value(.float(0.25)), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = length({in.uv} - {in.center}) - {in.radius};")),
        NodeDef(id: "sdf.box", title: "Box", category: .sdf,
                inputs: [SocketDecl(name: "uv", type: .concrete(.float2), default: .uv),
                         SocketDecl(name: "center", type: .concrete(.float2), default: .value(.float2(.init(0.5, 0.5))), range: -1...2),
                         SocketDecl(name: "size", type: .concrete(.float2), default: .value(.float2(.init(0.25, 0.25))), range: 0...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                requires: ["sdBox"],
                body: .template("{out.out} = mn_sdBox({in.uv} - {in.center}, {in.size});")),
        NodeDef(id: "sdf.union", title: "Union", category: .sdf,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)), range: -1...1),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(1)), range: -1...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = min({in.a}, {in.b});")),
        NodeDef(id: "sdf.subtract", title: "Subtract", category: .sdf,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)), range: -1...1),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(1)), range: -1...1)],
                outputs: [SocketDecl(name: "out", label: "Distance", type: .concrete(.float))],
                body: .template("{out.out} = max({in.a}, -{in.b});")),
    ]
}
