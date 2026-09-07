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

/// The RealityKit snippet has strictly more API surface than the stitchable one — `MTLDevice`,
/// `CustomMaterial`, its shader-function objects, and (in the texture branch) `TextureResource` —
/// so it gets the same `swiftc`-against-the-SDK gate as `ShaderExportTests
/// .generatedSwiftTypechecksWhenSwiftcIsAvailable`, stricter in one respect: that test only checks
/// `terminationStatus == 0`, which would not catch a *warning* (a `var` the snippet never mutates
/// typechecks fine — it only warns). This one also fails on any `warning:` line on stderr.
@Suite struct MaterialExportSwiftTypecheckTests {
    private func doc(exportName: String, offset: Bool, texture: Bool) -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.target = .realityKit
        d.settings.exportName = exportName
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
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
        d.root = g
        return d
    }

    /// Covers all four code paths the geometry/texture flags select, since each takes a different
    /// route through `swiftSnippet`.
    @Test func theGeneratedSwiftTypechecksWithNoWarningsForEveryStagePathWhenSwiftcIsAvailable() throws {
        guard xcrunSucceeds(["swiftc", "--version"]) else { return }
        let sdk = capture(["--show-sdk-path", "--sdk", "macosx"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdk, !sdk.isEmpty else { return }

        let variants: [(name: String, offset: Bool, texture: Bool)] = [
            ("noGeometryNoTexture", false, false),
            ("geometryOnly", true, false),
            ("textureOnly", false, true),
            ("geometryAndTexture", true, true),
        ]
        for v in variants {
            let d = doc(exportName: v.name, offset: v.offset, texture: v.texture)
            let shader = try ShaderGenerator.generate(d, target: d.settings.target)
            let snippet = MaterialExport.swiftSnippet(for: shader, document: d, registry: .builtin)

            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-materialswift-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("\(v.name).swift")
            try snippet.write(to: url, atomically: true, encoding: .utf8)

            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            p.arguments = ["swiftc", "-typecheck", "-strict-concurrency=complete",
                           "-sdk", sdk, "-target", "arm64-apple-macos26.0", url.path]
            let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice
            try p.run()
            let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            #expect(p.terminationStatus == 0, "\(v.name): \(log)")
            #expect(!log.contains("warning:"), "\(v.name) produced a warning:\n\(log)")
        }
    }

    private func xcrunSucceeds(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    private func capture(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
