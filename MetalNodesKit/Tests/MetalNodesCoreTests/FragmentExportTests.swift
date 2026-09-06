import Testing
import Foundation
import CoreGraphics
@testable import MetalNodesCore

/// `.metal` export for the fragment target (spec §21.3): `ShaderExport.files(for:)` writes one
/// `.metal` file whose leading comment documents the uniform layout and texture slots, then the
/// same source the preview compiles.
@Suite struct FragmentExportTests {
    private func id(_ n: Int) -> NodeID { NodeID(raw: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!) }
    private func aid(_ n: Int) -> AssetID { AssetID(raw: UUID(uuidString: String(format: "20000000-0000-0000-0000-%012d", n))!) }

    /// UV → two Texture Samples (one asset, one unassigned) → Mix Color → Output. Deterministic
    /// node ids so the header's field/texture order — and thus the whole string — is reproducible;
    /// `ShaderDocument.sample()` cannot be used for a literal compare because its nodes get fresh
    /// random ids each call, and ties between same-type/alignment uniform fields (see below) are
    /// broken by id order, so their relative order is not stable across runs.
    private func texturedDoc() -> ShaderDocument {
        var d = ShaderDocument()
        d.settings.assets[aid(1)] = AssetInfo(name: "rock.png", pixelSize: CGSize(width: 64, height: 64), fileExtension: "png")
        let uv = NodeInstance(id: id(1), kind: .builtin("input.uv"))
        let s1 = NodeInstance(id: id(2), kind: .builtin("texture.sample"), params: ["asset": .asset(aid(1))])
        let s2 = NodeInstance(id: id(3), kind: .builtin("texture.sample"), params: ["asset": .asset(nil)])
        let mix = NodeInstance(id: id(4), kind: .builtin("color.mixcolor"), params: ["mode": .enumCase("mix")])
        let out = NodeInstance(id: id(5), kind: .builtin("output.fragment"))
        for n in [uv, s1, s2, mix, out] { d.root.nodes[n.id] = n }
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s1.id, "uv"))
        d.root.connect(SocketRef(uv.id, "uv"), to: SocketRef(s2.id, "uv"))
        d.root.connect(SocketRef(s1.id, "color"), to: SocketRef(mix.id, "a"))
        d.root.connect(SocketRef(s2.id, "color"), to: SocketRef(mix.id, "b"))
        d.root.connect(SocketRef(mix.id, "out"), to: SocketRef(out.id, "color"))
        d.settings.exportName = "textured"
        return d
    }

    @Test func fragmentHeaderGoldenForATexturedDocument() throws {
        let d = texturedDoc()
        let shader = try ShaderGenerator.generate(d, registry: .builtin)
        let header = ShaderExport.fragmentHeader(for: shader, document: d, registry: .builtin)
        let expected = """
        // MetalNodes fragment shader "textured"
        // Uniforms (buffer 0):
        //   0  float2  resolution
        //   8  float2  mouse
        //   16  float  time
        //   20  float  p0  ← Mix Color · Factor
        // Textures:
        //   texture(0)  unassigned
        //   texture(1)  rock.png


        """
        #expect(header == expected)
    }

    @Test func filesForTheTexturedDocumentPrependsTheHeaderToTheSource() throws {
        let d = texturedDoc()
        let files = try ShaderExport.files(for: d, registry: .builtin)
        #expect(files.map(\.name) == ["textured.metal"])
        let shader = try ShaderGenerator.generate(d, registry: .builtin)
        #expect(files[0].contents == ShaderExport.fragmentHeader(for: shader, document: d, registry: .builtin) + shader.source)
    }

    /// `ShaderDocument.sample()` has no textures and three uniform slots, two of which (a plain
    /// float "value" and a plain float "scale") tie in size/alignment and so land in either
    /// relative order (see `texturedDoc()`'s doc comment) — assert the order-independent parts
    /// exactly and each variable line by substring rather than one brittle whole-string compare.
    @Test func fragmentHeaderForSample() throws {
        var d = ShaderDocument.sample(); d.settings.exportName = "sample"
        let shader = try ShaderGenerator.generate(d, registry: .builtin)
        let header = ShaderExport.fragmentHeader(for: shader, document: d, registry: .builtin)
        #expect(header.hasPrefix("""
        // MetalNodes fragment shader "sample"
        // Uniforms (buffer 0):
        //   0  float4  p0  ← Color · Value
        //   16  float2  resolution
        //   24  float2  mouse
        //   32  float  time

        """))
        #expect(header.contains("//   36  float  p1  ← Float · Value\n") || header.contains("//   40  float  p2  ← Float · Value\n"))
        #expect(header.contains("//   36  float  p1  ← Value Noise · Scale\n") || header.contains("//   40  float  p2  ← Value Noise · Scale\n"))
        #expect(header.hasSuffix("// Textures:\n\n"))

        let files = try ShaderExport.files(for: d, registry: .builtin)
        #expect(files.map(\.name) == ["sample.metal"])
        #expect(files[0].contents.hasPrefix(header))
        #expect(files[0].contents.contains("\n\n#include <metal_stdlib>\n"))
        #expect(files[0].contents.contains("fragment float4 shaderMain"))
    }

    /// The export must be a valid Metal file. `xcrun metal` is not always installed; skip silently
    /// when it is not (copied from `ShaderExportTests.exportedMetalCompilesWithTheToolchainWhenAvailable`).
    @Test func exportedFragmentMetalCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        var sample = ShaderDocument.sample(); sample.settings.exportName = "sample"
        for d in [sample, texturedDoc()] {
            let files = try ShaderExport.files(for: d, registry: .builtin)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-fragexport-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(files[0].name)
            try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
            let metal = Process()
            metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
            let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
            try metal.run(); metal.waitUntilExit()
            let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            #expect(metal.terminationStatus == 0, "\(d.settings.exportName): \(log)")
        }
    }
}
