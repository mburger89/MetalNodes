import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// Layer-parameter group variants (spec §22.7): under the Layer Effect **export**, a definition
/// whose transitive body samples gets a second `…_layer` function that reads SwiftUI's `Layer`
/// instead of a `texture2d<float>` parameter. The fragment and preview programs are untouched.
@Suite struct LayerVariantTests {
    let reg = NodeRegistry.builtin
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func gid(_ n: Int) -> GroupID { GroupID(raw: UUID(uuidString: String(format: "1000000%d-0000-0000-0000-000000000000", n))!) }
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    /// Definition “Tex” (`gid(1)`): one Texture Sample of asset 2 → Group Output. Instantiated once
    /// in a root that is nothing but that instance and the Fragment Output. Every id is fixed, so
    /// the whole export is reproducible and can be compared as one string. The group ids differ in
    /// their *first* eight hex digits, because that prefix is what names the MSL struct.
    private func sampling() -> ShaderDocument {
        var def = GroupDefinition(id: gid(1), name: "Tex", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(10), kind: .groupInput)
        let gout = NodeInstance(id: id(11), kind: .groupOutput)
        let sample = NodeInstance(id: id(12), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        for n in [gin, gout, sample] { def.graph.nodes[n.id] = n }
        def.graph.connect(SocketRef(sample.id, "color"), to: SocketRef(gout.id, "color"))

        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let inst = NodeInstance(id: id(1), kind: .group(def.id))
        let out = NodeInstance(id: id(2), kind: .builtin("output.fragment"))
        d.root.nodes[inst.id] = inst; d.root.nodes[out.id] = out
        d.root.connect(SocketRef(inst.id, "color"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"
        return d
    }

    /// “Outer” (`gid(3)`) samples nothing itself: it only instantiates “Tex”. The root instantiates
    /// “Outer”. Containment is transitive, so both get a `_layer` variant.
    private func nested() -> ShaderDocument {
        var d = sampling()
        var outer = GroupDefinition(id: gid(3), name: "Outer", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(20), kind: .groupInput)
        let gout = NodeInstance(id: id(21), kind: .groupOutput)
        let inner = NodeInstance(id: id(22), kind: .group(gid(1)))
        for n in [gin, gout, inner] { outer.graph.nodes[n.id] = n }
        outer.graph.connect(SocketRef(inner.id, "color"), to: SocketRef(gout.id, "color"))
        d.definitions[outer.id] = outer
        d.root.remove(node: id(1))
        let oi = NodeInstance(id: id(3), kind: .group(outer.id))
        d.root.nodes[oi.id] = oi
        d.root.connect(SocketRef(oi.id, "color"), to: SocketRef(id(2), "color"))
        return d
    }

    @Test func groupedSampleExportsALayerVariant() throws {
        let s = try ShaderGenerator.generate(sampling(), target: .stitchable(.layerEffect), registry: reg)
        let expected = """
        #include <metal_stdlib>
        #include <SwiftUI/SwiftUI_Metal.h>
        using namespace metal;

        constexpr sampler mn_sampler(filter::linear, address::repeat);

        struct G_10000001_Out {
            float4 color;
        };

        G_10000001_Out mn_g_Tex_10000001_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            float4 v0;
            float v1;
            float4 v0_s = float4(layer.sample(position));
            v0 = v0_s;
            v1 = v0_s.w;
            G_10000001_Out out;
            out.color = v0;
            return out;
        }

        [[stitchable]] half4 fx(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            G_10000001_Out r0 = mn_g_Tex_10000001_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            return half4(v1);
        }

        """
        #expect(s.exportSource == expected)
    }

    @Test func theExportBindsNothingWhileThePreviewStillBindsTheAsset() throws {
        let s = try ShaderGenerator.generate(sampling(), target: .stitchable(.layerEffect), registry: reg)
        #expect(s.textures == [TextureSlot(index: 0, asset: aid(2))])
        #expect(!s.exportSource!.contains("texture2d"))
        #expect(!s.exportSource!.contains("tex0"))
        #expect(s.source.contains("texture2d<float> tex0 [[texture(0)]]"))
        #expect(s.source.contains("mn_g_Tex_10000001(float2 uv, float time, float2 size, float2 mouse, texture2d<float> t_20000000)"))
        #expect(s.source.contains("mn_g_Tex_10000001(uv, time, size, mouse, tex0)"))
        #expect(!s.source.contains("_layer"))
    }

    @Test func nestedDefinitionsGetLayerVariantsTransitively() throws {
        let s = try ShaderGenerator.generate(nested(), target: .stitchable(.layerEffect), registry: reg)
        let expected = """
        #include <metal_stdlib>
        #include <SwiftUI/SwiftUI_Metal.h>
        using namespace metal;

        constexpr sampler mn_sampler(filter::linear, address::repeat);

        struct G_10000001_Out {
            float4 color;
        };

        G_10000001_Out mn_g_Tex_10000001_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            float4 v0;
            float v1;
            float4 v0_s = float4(layer.sample(position));
            v0 = v0_s;
            v1 = v0_s.w;
            G_10000001_Out out;
            out.color = v0;
            return out;
        }

        struct G_10000003_Out {
            float4 color;
        };

        G_10000003_Out mn_g_Outer_10000003_layer(float2 uv, float time, float2 size, float2 mouse, SwiftUI::Layer layer, float2 position) {
            G_10000001_Out r0 = mn_g_Tex_10000001_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            G_10000003_Out out;
            out.color = v1;
            return out;
        }

        [[stitchable]] half4 fx(float2 position, SwiftUI::Layer layer, float2 size, float time, float2 mouse) {
            float2 uv = float2(position.x / size.x, 1.0 - position.y / size.y);
            G_10000003_Out r0 = mn_g_Outer_10000003_layer(uv, time, size, mouse, layer, position);
            float4 v1;
            v1 = r0.color;
            return half4(v1);
        }

        """
        #expect(s.exportSource == expected)
    }

    /// A definition that samples nothing needs no second function: the export emits it once, under
    /// its ordinary name, even though the root itself samples the layer.
    @Test func aDefinitionWithoutASampleKeepsOneFunction() throws {
        var def = GroupDefinition(id: gid(5), name: "Half",
                                  inputs: [SocketDecl(name: "a", type: .concrete(.color), default: .value(.float4(.init(0, 0, 0, 1))))],
                                  outputs: [SocketDecl(name: "out", type: .concrete(.color))])
        let gin = NodeInstance(id: id(30), kind: .groupInput)
        let gout = NodeInstance(id: id(31), kind: .groupOutput)
        for n in [gin, gout] { def.graph.nodes[n.id] = n }
        def.graph.connect(SocketRef(gin.id, "a"), to: SocketRef(gout.id, "out"))

        var d = ShaderDocument()
        d.settings.assets[aid(2)] = AssetInfo(name: "a.png", pixelSize: CGSize(width: 2, height: 2), fileExtension: "png")
        d.definitions[def.id] = def
        let sample = NodeInstance(id: id(4), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(2))])
        let inst = NodeInstance(id: id(5), kind: .group(def.id))
        let out = NodeInstance(id: id(6), kind: .builtin("output.fragment"))
        for n in [sample, inst, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(sample.id, "color"), to: SocketRef(inst.id, "a"))
        d.root.connect(SocketRef(inst.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.target = .stitchable(.layerEffect)
        d.settings.exportName = "fx"

        let s = try ShaderGenerator.generate(d, target: d.settings.target, registry: reg)
        let export = try #require(s.exportSource)
        #expect(!export.contains("_layer"))
        #expect(export.components(separatedBy: "mn_g_Half_10000005").count == 3)   // one definition, one call
        #expect(export.contains("float4(layer.sample(position))"))                 // the root's own sample
        #expect(!export.contains("texture2d"))
    }

    /// Only the definitions the root's program emits, sorted by id (spec §22.6).
    @Test func reachableDefinitionsListsWhatTheRootInstantiates() throws {
        var d = nested()
        var stray = GroupDefinition(id: gid(7), name: "Stray", outputs: [SocketDecl(name: "color", type: .concrete(.color))])
        let gin = NodeInstance(id: id(40), kind: .groupInput)
        let gout = NodeInstance(id: id(41), kind: .groupOutput)
        for n in [gin, gout] { stray.graph.nodes[n.id] = n }
        d.definitions[stray.id] = stray
        #expect(GraphValidator.reachableDefinitions(d).map(\.id) == [gid(1), gid(3)])
        #expect(GraphValidator.reachableDefinitions(ShaderDocument.sample()).isEmpty)
    }

    /// The Layer Effect export with a grouped sample must be a valid Metal file — `SwiftUI::Layer`
    /// comes from `#include <SwiftUI/SwiftUI_Metal.h>`, which the macOS SDK provides. `xcrun metal`
    /// is not always installed; skip silently when it is not (probe copied from `FragmentExportTests`).
    @Test func theLayerExportCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        for d in [sampling(), nested()] {
            let files = try ShaderExport.files(for: d, registry: reg)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-layer-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(files[0].name)
            try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
            let metal = Process()
            metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
            let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
            try metal.run(); metal.waitUntilExit()
            let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(metal.terminationStatus == 0, "\(d.definitions.count) definitions: \(log)")
        }
    }
}
