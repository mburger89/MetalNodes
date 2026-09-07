import Foundation
import Testing
@testable import MetalNodesCore

@Suite struct MaterialExportTests {
    private func document(offset: Bool = true, texture: Bool = false,
                          lighting: MaterialLightingModel = .lit) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "brickMaterial"
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var rough = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        rough.params["value"] = .float(0.35)
        g.nodes[terminal.id] = terminal
        g.nodes[rough.id] = rough
        g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(rough.id, "out")
        if offset {
            let v = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
            g.nodes[v.id] = v
            g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(v.id, "out")
        }
        if texture {
            let s = NodeInstance(id: NodeID(), kind: .builtin("texture.sample"), position: .zero)
            g.nodes[s.id] = s
            g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(s.id, "color")
        }
        doc.root = g
        return doc
    }

    private func files(_ doc: ShaderDocument) throws -> [ExportFile] {
        try ShaderExport.files(for: doc)
    }

    @Test func twoFilesAreWrittenWithTheExportName() throws {
        let f = try files(document())
        #expect(f.map(\.name).sorted() == ["brickMaterial.metal", "brickMaterial.swift"])
    }

    @Test func theHeaderDocumentsTargetLightingAndBakedParameters() throws {
        let metal = try #require(files(document()).first { $0.name.hasSuffix(".metal") })
        #expect(metal.contents.contains("RealityKit CustomMaterial"))
        #expect(metal.contents.contains("Lighting model: lit"))
        #expect(metal.contents.contains("0.35"))
        #expect(metal.contents.contains("Float · Value") || metal.contents.contains("Float"))
        // The header explains that parameters are frozen, because that is surprising.
        #expect(metal.contents.lowercased().contains("baked"))
    }

    @Test func theSnippetBuildsBothShaderObjectsAndTheMaterial() throws {
        let swift = try #require(files(document()).first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("import RealityKit"))
        #expect(swift.contents.contains("CustomMaterial.SurfaceShader(named: \"brickMaterial_surface\""))
        #expect(swift.contents.contains("CustomMaterial.GeometryModifier(named: \"brickMaterial_geometry\""))
        #expect(swift.contents.contains("lightingModel: .lit"))
    }

    /// Apple: a modifier that moves vertices outside the original bounds can get the entity culled.
    @Test func theSnippetMentionsBoundsMarginOnlyWhenThereIsAGeometryModifier() throws {
        let withOffset = try #require(files(document(offset: true)).first { $0.name.hasSuffix(".swift") })
        #expect(withOffset.contents.contains("boundsMargin"))

        let without = try #require(files(document(offset: false)).first { $0.name.hasSuffix(".swift") })
        #expect(!without.contents.contains("boundsMargin"))
        #expect(!without.contents.contains("GeometryModifier"))
    }

    @Test func theSnippetAssignsTheCustomTextureWhenTheGraphSamples() throws {
        let sampled = try #require(files(document(texture: true)).first { $0.name.hasSuffix(".swift") })
        #expect(sampled.contents.contains("custom.texture"))

        let plain = try #require(files(document()).first { $0.name.hasSuffix(".swift") })
        #expect(!plain.contents.contains("custom.texture"))
    }

    @Test func unlitIsCarriedIntoTheSnippet() throws {
        let swift = try #require(files(document(lighting: .unlit)).first { $0.name.hasSuffix(".swift") })
        #expect(swift.contents.contains("lightingModel: .unlit"))
    }

    @Test func exportIsDeterministic() throws {
        let doc = document(texture: true)
        #expect(try files(doc) == (try files(doc)))
    }

    /// The other targets must be untouched by the new branch.
    @Test func fragmentAndStitchableExportsAreUnchanged() throws {
        var doc = ShaderDocument()
        var g = Graph()
        let t = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        g.nodes[t.id] = t
        doc.root = g
        #expect(try ShaderExport.files(for: doc).map(\.name) == ["metalNodesShader.metal"])
        doc.settings.target = .stitchable(.colorEffect)
        #expect(try ShaderExport.files(for: doc).map(\.name).sorted()
                == ["metalNodesShader.metal", "metalNodesShader.swift"])
    }
}

@Suite struct MaterialExportCompilesTests {
    /// The exported `.metal` must compile against the SDK. The RealityKit headers ship in the SDK
    /// even though the running OS does not carry them — which is precisely why the *runtime*
    /// compiler cannot build this file and the preview needs its own program (spec §23.4).
    ///
    /// Follows the same skip mechanism as `ShaderExportTests.exportedMetalCompilesWithTheToolchainWhenAvailable`
    /// and `FragmentExportTests.exportedFragmentMetalCompilesWithTheToolchainWhenAvailable`: probe with
    /// `xcrun -sdk macosx metal --version` and skip silently when the toolchain is not available.
    @Test func theExportedMetalCompilesWithXcrunMetal() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.settings.exportName = "compileCheck"
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var color = NodeInstance(id: NodeID(), kind: .builtin("input.color"), position: .zero)
        color.params["value"] = .float4(.init(1, 0.5, 0.25, 1))
        let offset = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        for n in [terminal, color, offset] { g.nodes[n.id] = n }
        g.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(color.id, "out")
        g.inputs[SocketRef(terminal.id, "positionOffset")] = SocketRef(offset.id, "out")
        doc.root = g

        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-materialexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.name)
        try file.contents.write(to: url, atomically: true, encoding: .utf8)
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
        try metal.run(); metal.waitUntilExit()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(metal.terminationStatus == 0, "\(log)")
    }
}
