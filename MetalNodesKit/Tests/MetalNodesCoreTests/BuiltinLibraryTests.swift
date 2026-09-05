import Testing
@testable import MetalNodesCore

@Suite struct BuiltinLibraryTests {
    @Test func registryContainsTheV1Set() {
        let ids = Set(NodeRegistry.builtin.all.map(\.id))
        let expected: Set<String> = [
            "input.uv", "input.time", "input.resolution", "input.float", "input.color",
            "math.math", "math.mix", "math.smoothstep",
            "vector.combine", "vector.separate", "vector.length",
            "noise.value", "output.fragment",
            "input.float2", "input.float3", "input.int", "input.bool", "input.mouse",
            "math.clamp", "math.step", "math.maprange",
            "vector.dot", "vector.normalize", "vector.rotate2d",
        ]
        #expect(ids == expected)
    }

    @Test func everyRequiredStdlibFunctionExists() {
        for def in NodeRegistry.builtin.all {
            for name in def.requires {
                #expect(MSLStdlib.functions[name] != nil, "\(def.id) requires \(name)")
            }
        }
    }

    @Test func stdlibResolvesDependenciesInOrderWithoutDuplicates() {
        let fns = MSLStdlib.resolve(["valueNoise", "valueNoise", "hash21"]).map(\.name)
        #expect(fns == ["hash21", "valueNoise"])
    }

    @Test func mathNodeHasFifteenVariants() throws {
        let def = try #require(NodeRegistry.builtin["math.math"])
        guard case .variants(let param, let table) = def.body else { Issue.record("expected variants"); return }
        #expect(param == "op")
        #expect(table.count == 15)
    }

    @Test func sampleDocumentHasOneOutputAndWires() {
        let doc = ShaderDocument.sample()
        let outputs = doc.root.nodes.values.filter { $0.kind == .builtin("output.fragment") }
        #expect(outputs.count == 1)
        #expect(doc.root.inputs.count >= 8)
        #expect(doc.definitions.isEmpty)
    }

    @Test func noiseScaleRangeContainsSampleDefault() throws {
        let decl = try #require(NodeRegistry.builtin["noise.value"]!.input(named: "scale"))
        #expect(try #require(decl.range).contains(6))
    }
}
