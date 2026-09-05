import Foundation

extension BuiltinNodes {
    static let anyValue: [SocketType] = [.float, .float2, .float3, .float4, .color, .int, .bool]

    static let utility: [NodeDef] = [
        NodeDef(id: "utility.reroute", title: "Reroute", category: .utility,
                inputs: [SocketDecl(name: "in", label: "In", type: .generic("T"), default: .value(.float(0)))],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": anyValue],
                body: .template("{out.out} = {in.in};"),
                style: .dot),
        NodeDef(id: "utility.compare", title: "Compare", category: .utility,
                inputs: [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(0)), range: -10...10),
                         SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(0)), range: -10...10)],
                outputs: [SocketDecl(name: "out", label: "Result", type: .concrete(.bool))],
                params: [ParamDecl(name: "op", label: "Operation", kind: .enumeration(["less", "greater", "equal", "notEqual"]), defaultValue: .enumCase("less"))],
                body: .variants(param: "op", [
                    "less": "{out.out} = {in.a} < {in.b};",
                    "greater": "{out.out} = {in.a} > {in.b};",
                    "equal": "{out.out} = abs({in.a} - {in.b}) < 0.0001;",
                    "notEqual": "{out.out} = abs({in.a} - {in.b}) >= 0.0001;",
                ])),
        NodeDef(id: "utility.switch", title: "Switch", category: .utility,
                inputs: [SocketDecl(name: "cond", label: "Condition", type: .concrete(.bool), default: .value(.bool(false))),
                         SocketDecl(name: "a", label: "True", type: .generic("T"), default: .value(.float(1)), range: -10...10),
                         SocketDecl(name: "b", label: "False", type: .generic("T"), default: .value(.float(0)), range: -10...10)],
                outputs: [SocketDecl(name: "out", type: .generic("T"))],
                generics: ["T": [.float, .float2, .float3, .float4, .color]],
                body: .template("{out.out} = {in.cond} ? {in.a} : {in.b};")),
    ]
}
