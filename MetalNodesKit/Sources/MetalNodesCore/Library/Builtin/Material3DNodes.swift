import Foundation

extension BuiltinNodes {
    /// Which stage each Material Output socket belongs to (spec §23.2). Eight surface sockets and
    /// one geometry socket; the generator partitions the graph by this map.
    public static let materialStages: [String: MaterialStage] = [
        "baseColor": .surface, "normal": .surface, "roughness": .surface, "metallic": .surface,
        "emissive": .surface, "opacity": .surface, "occlusion": .surface, "specular": .surface,
        "positionOffset": .geometry,
    ]

    /// The RealityKit terminal and the per-vertex/per-fragment builtins only that target can read
    /// (spec §23.2, §23.3). Every body spells its value as `{sys.…}`, so one definition serves both
    /// stages and the `EmitEnvironment` decides the accessor.
    public static let material3D: [NodeDef] = [
        NodeDef(id: "output.material", title: "Material Output", category: .output,
                inputs: [
                    SocketDecl(name: "baseColor", label: "Base Color", type: .concrete(.color),
                               default: .value(.float4(.init(0.8, 0.8, 0.8, 1)))),
                    SocketDecl(name: "normal", label: "Normal", type: .concrete(.float3),
                               default: .value(.float3(.init(0, 0, 1)))),
                    SocketDecl(name: "roughness", label: "Roughness", type: .concrete(.float),
                               default: .value(.float(0.5))),
                    SocketDecl(name: "metallic", label: "Metallic", type: .concrete(.float),
                               default: .value(.float(0))),
                    SocketDecl(name: "emissive", label: "Emissive", type: .concrete(.color),
                               default: .value(.float4(.init(0, 0, 0, 1)))),
                    SocketDecl(name: "opacity", label: "Opacity", type: .concrete(.float),
                               default: .value(.float(1))),
                    SocketDecl(name: "occlusion", label: "Ambient Occlusion", type: .concrete(.float),
                               default: .value(.float(1))),
                    SocketDecl(name: "specular", label: "Specular", type: .concrete(.float),
                               default: .value(.float(0.5))),
                    SocketDecl(name: "positionOffset", label: "Position Offset", type: .concrete(.float3),
                               default: .value(.float3(.init(0, 0, 0)))),
                ],
                // Never emitted: `MaterialCodegen` writes each stage's setter block itself,
                // because one body cannot serve two stages with different setters (spec §23.2).
                // `.custom` rather than an empty template because the emitter reads a template to
                // decide which inputs are live: an empty one claims the terminal reads none of its
                // nine sockets, so an unwired one would get no uniform slot, no baked literal and
                // no setter — and spec §23.2 requires all eight surface setters, defaults included.
                // `.custom` marks every input live and still contributes no statement of its own.
                body: .custom { _ in [] }),

        NodeDef(id: "input.worldPosition", title: "World Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float3))],
                body: .template("{out.position} = {sys.worldPosition};")),
        NodeDef(id: "input.modelPosition", title: "Model Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float3))],
                body: .template("{out.position} = {sys.modelPosition};")),
        NodeDef(id: "input.normal3d", title: "Normal", category: .input,
                outputs: [SocketDecl(name: "normal", type: .concrete(.float3))],
                body: .template("{out.normal} = {sys.normal3d};")),
        NodeDef(id: "input.tangent", title: "Tangent", category: .input,
                outputs: [SocketDecl(name: "tangent", type: .concrete(.float3))],
                stages: [.surface],
                body: .template("{out.tangent} = {sys.tangent};")),
        NodeDef(id: "input.bitangent", title: "Bitangent", category: .input,
                outputs: [SocketDecl(name: "bitangent", type: .concrete(.float3))],
                body: .template("{out.bitangent} = {sys.bitangent};")),
        NodeDef(id: "input.viewDirection", title: "View Direction", category: .input,
                outputs: [SocketDecl(name: "direction", type: .concrete(.float3))],
                stages: [.surface],
                body: .template("{out.direction} = {sys.viewDirection};")),
        NodeDef(id: "input.uv1", title: "UV1", category: .input,
                outputs: [SocketDecl(name: "uv", type: .concrete(.float2))],
                body: .template("{out.uv} = {sys.uv1};")),
        NodeDef(id: "input.vertexColor", title: "Vertex Color", category: .input,
                outputs: [SocketDecl(name: "color", type: .concrete(.color))],
                body: .template("{out.color} = {sys.vertexColor};")),
        NodeDef(id: "input.vertexID", title: "Vertex ID", category: .input,
                outputs: [SocketDecl(name: "id", type: .concrete(.int))],
                stages: [.geometry],
                body: .template("{out.id} = {sys.vertexID};")),
        NodeDef(id: "input.screenPosition", title: "Screen Position", category: .input,
                outputs: [SocketDecl(name: "position", type: .concrete(.float4))],
                stages: [.surface],
                body: .template("{out.position} = {sys.screenPosition};")),
    ]
}
