import Testing
@testable import MetalNodesCore

@Suite struct Material3DLibraryTests {
    private func def(_ id: String) -> NodeDef {
        guard let d = NodeRegistry.builtin[id] else { Issue.record("missing node \(id)"); return NodeDef(id: id, title: id, category: .input, body: .template("")) }
        return d
    }

    @Test func theMaterialOutputHasNineSocketsInSpecOrder() {
        let d = def("output.material")
        #expect(d.category == .output)
        #expect(d.inputs.map(\.name) == ["baseColor", "normal", "roughness", "metallic",
                                         "emissive", "opacity", "occlusion", "specular", "positionOffset"])
        #expect(d.outputs.isEmpty)
    }

    @Test func materialOutputSocketTypesMatchTheSetterTable() {
        let types = Dictionary(uniqueKeysWithValues: def("output.material").inputs.map { ($0.name, $0.type) })
        #expect(types["baseColor"] == .concrete(.color))
        #expect(types["normal"] == .concrete(.float3))
        #expect(types["roughness"] == .concrete(.float))
        #expect(types["metallic"] == .concrete(.float))
        #expect(types["emissive"] == .concrete(.color))
        #expect(types["opacity"] == .concrete(.float))
        #expect(types["occlusion"] == .concrete(.float))
        #expect(types["specular"] == .concrete(.float))
        #expect(types["positionOffset"] == .concrete(.float3))
    }

    @Test func eightSocketsAreSurfaceAndOneIsGeometry() {
        let surface = BuiltinNodes.materialStages.filter { $0.value == .surface }.keys.sorted()
        #expect(surface == ["baseColor", "emissive", "metallic", "normal", "occlusion", "opacity", "roughness", "specular"])
        #expect(BuiltinNodes.materialStages["positionOffset"] == .geometry)
        // Every socket of the terminal has a stage; none is unclassified.
        #expect(Set(def("output.material").inputs.map(\.name)) == Set(BuiltinNodes.materialStages.keys))
    }

    @Test func stageOnlyNodesDeclareTheirStage() {
        #expect(def("input.tangent").stages == [.surface])
        #expect(def("input.viewDirection").stages == [.surface])
        #expect(def("input.screenPosition").stages == [.surface])
        #expect(def("input.vertexID").stages == [.geometry])
        for id in ["input.worldPosition", "input.modelPosition", "input.normal3d",
                   "input.bitangent", "input.uv1", "input.vertexColor"] {
            #expect(def(id).stages == MaterialStage.all, "\(id)")
        }
    }

    @Test func theThreeDimensionalInputsOutputTheDeclaredTypes() {
        let expected: [String: SocketType] = [
            "input.worldPosition": .float3, "input.modelPosition": .float3, "input.normal3d": .float3,
            "input.tangent": .float3, "input.bitangent": .float3, "input.viewDirection": .float3,
            "input.uv1": .float2, "input.vertexColor": .color, "input.vertexID": .int,
            "input.screenPosition": .float4,
        ]
        for (id, type) in expected {
            let d = def(id)
            #expect(d.outputs.count == 1, "\(id)")
            #expect(d.outputs.first?.type == .concrete(type), "\(id)")
            #expect(d.category == .input, "\(id)")
        }
    }

    /// Every `{sys.x}` a 3D node names must be a key both RealityKit environments provide,
    /// otherwise the emitter substitutes a comment marker into real source.
    @Test func everySysPlaceholderIsAKnownSystemName() {
        let known: Set<String> = ["uv", "time", "resolution", "mouse", "uv1", "worldPosition",
                                  "modelPosition", "normal3d", "tangent", "bitangent",
                                  "viewDirection", "vertexColor", "vertexID", "screenPosition"]
        for d in BuiltinNodes.material3D {
            guard case .template(let t) = d.body else { continue }
            for m in t.matches(of: NodeRegistry.placeholderPattern) where m.1 == "sys" {
                #expect(known.contains(String(m.2)), "\(d.id) names {sys.\(m.2)}")
            }
        }
    }
}
