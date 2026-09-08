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
        try expectMetalCompiles(doc)

        // Task 12 (spec §24.6): a live parameter changes what a field's `Uniforms` accessor spells
        // (`params.uniforms().custom_parameter().x` instead of a literal) — its own `.metal` shape,
        // unexercised by the document above, which has none.
        var liveDoc = ShaderDocument()
        liveDoc.settings.target = .realityKit
        liveDoc.settings.exportName = "liveCompileCheck"
        var lg = Graph()
        let liveTerminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var rough = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        rough.params["value"] = .float(0.4)
        lg.nodes[liveTerminal.id] = liveTerminal
        lg.nodes[rough.id] = rough
        lg.inputs[SocketRef(liveTerminal.id, "roughness")] = SocketRef(rough.id, "out")
        liveDoc.root = lg
        liveDoc.settings.liveParameters = [ParamPath(node: rough.id, param: "value")]
        try expectMetalCompiles(liveDoc)

        // Task 13 (spec §24.7): `.clearcoat` emits three more setters than `.lit`, one of them —
        // `set_clearcoat_normal` — behind the availability trap the header must also note. Both the
        // unwired shape (default clearcoat normal, no note) and the wired shape (the note, and a
        // real expression reaching `set_clearcoat_normal`) get their own `.metal` here so the gate
        // that actually runs `xcrun -sdk macosx metal -c` covers both, not just the text assertions
        // in `ClearcoatTests`.
        var clearcoatDoc = ShaderDocument()
        clearcoatDoc.settings.target = .realityKit
        clearcoatDoc.settings.exportName = "clearcoatCompileCheck"
        clearcoatDoc.settings.lightingModel = .clearcoat
        var ccg = Graph()
        let ccTerminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        var ccStrength = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
        ccStrength.params["value"] = .float(0.6)
        ccg.nodes[ccTerminal.id] = ccTerminal
        ccg.nodes[ccStrength.id] = ccStrength
        ccg.inputs[SocketRef(ccTerminal.id, "clearcoat")] = SocketRef(ccStrength.id, "out")
        clearcoatDoc.root = ccg
        try expectMetalCompiles(clearcoatDoc)

        // Fix round 1: this is the trap turned into a real gate, not just a comment. Before this
        // task's fix, `set_clearcoat_normal` was emitted unconditionally under `.clearcoat` — even
        // completely unwired — and the header's macro is `__attribute__((availability(macos,
        // introduced=15.0, strict)))`: `strict` makes referencing it below the floor a hard
        // *compile* error, not a warning. `clearcoatDoc` above never wires Clearcoat Normal, so
        // compiling it with an explicit macOS 14 floor is exactly the scenario that used to fail —
        // it must now succeed, because the unwired setter call is skipped entirely.
        try expectMetalCompiles(clearcoatDoc, extraArgs: ["-mmacosx-version-min=14.0"])

        var clearcoatNormalDoc = ShaderDocument()
        clearcoatNormalDoc.settings.target = .realityKit
        clearcoatNormalDoc.settings.exportName = "clearcoatNormalCompileCheck"
        clearcoatNormalDoc.settings.lightingModel = .clearcoat
        var ccng = Graph()
        let ccnTerminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        let ccnNormal = NodeInstance(id: NodeID(), kind: .builtin("input.normal3d"), position: .zero)
        ccng.nodes[ccnTerminal.id] = ccnTerminal
        ccng.nodes[ccnNormal.id] = ccnNormal
        ccng.inputs[SocketRef(ccnTerminal.id, "clearcoatNormal")] = SocketRef(ccnNormal.id, "normal")
        clearcoatNormalDoc.root = ccng
        try expectMetalCompiles(clearcoatNormalDoc)
    }

    /// Writes `doc`'s exported `.metal` to a temp file and runs `xcrun -sdk macosx metal -c` over
    /// it, failing the current test with the compiler's stderr on a nonzero exit. `extraArgs` is
    /// spliced in ahead of `-c` — e.g. `-mmacosx-version-min=…`, to pin a real deployment floor
    /// rather than the toolchain's own default.
    private func expectMetalCompiles(_ doc: ShaderDocument, extraArgs: [String] = []) throws {
        let file = try #require(ShaderExport.files(for: doc).first { $0.name.hasSuffix(".metal") })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-materialexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(file.name)
        try file.contents.write(to: url, atomically: true, encoding: .utf8)
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal"] + extraArgs
            + ["-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
        try metal.run(); metal.waitUntilExit()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(metal.terminationStatus == 0,
               "\(doc.settings.exportName)\(extraArgs.isEmpty ? "" : " \(extraArgs.joined(separator: " "))"): \(log)")
    }
}

/// The RealityKit snippet has strictly more API surface than the stitchable one — `MTLDevice`,
/// `CustomMaterial`, its shader-function objects, and (in the texture branch) `TextureResource` —
/// so it gets the same `swiftc`-against-the-SDK gate as `ShaderExportTests
/// .generatedSwiftTypechecksWhenSwiftcIsAvailable`, stricter in one respect: that test only checks
/// `terminationStatus == 0`, which would not catch a *warning* (a `var` the snippet never mutates
/// typechecks fine — it only warns). This one also fails on any `warning:` line on stderr.
@Suite struct MaterialExportSwiftTypecheckTests {
    private func doc(exportName: String, offset: Bool, texture: Bool, live: Bool = false,
                     clearcoatNormal: Bool = false) -> ShaderDocument {
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
        if live {
            // Exercises the `hasLive` branch `swiftSnippet` gained in Task 12 (spec §24.6): a
            // `var material` built even with no texture, and the `material.custom.value =
            // SIMD4<Float>(...)` setter — neither existed before that task, and neither was
            // covered by this gate until now.
            let f = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
            g.nodes[f.id] = f
            g.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(f.id, "out")
            d.settings.liveParameters = [ParamPath(node: f.id, param: "value")]
        }
        if clearcoatNormal {
            // Task 13 (spec §24.7): the availability note this branch adds to `make()`'s doc
            // comment must itself still typecheck as a doc comment — a malformed one would not
            // fail `swiftc -typecheck`, so this exists mainly to keep the branch exercised here
            // rather than only asserted as text in `ClearcoatTests`.
            d.settings.lightingModel = .clearcoat
            let n = NodeInstance(id: NodeID(), kind: .builtin("input.normal3d"), position: .zero)
            g.nodes[n.id] = n
            g.inputs[SocketRef(terminal.id, "clearcoatNormal")] = SocketRef(n.id, "normal")
        }
        d.root = g
        return d
    }

    /// Covers all four code paths the geometry/texture flags select, since each takes a different
    /// route through `swiftSnippet` — plus the two live-parameter paths Task 12 added: live alone
    /// (the `hasLive`-but-not-`hasTexture` branch) and live with a texture (both flags true at
    /// once, which `hasTexture || hasLive`'s shared `var material` path must still handle cleanly).
    @Test func theGeneratedSwiftTypechecksWithNoWarningsForEveryStagePathWhenSwiftcIsAvailable() throws {
        guard xcrunSucceeds(["swiftc", "--version"]) else { return }
        let sdk = capture(["--show-sdk-path", "--sdk", "macosx"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sdk, !sdk.isEmpty else { return }

        let variants: [(name: String, offset: Bool, texture: Bool, live: Bool, clearcoatNormal: Bool)] = [
            ("noGeometryNoTexture", false, false, false, false),
            ("geometryOnly", true, false, false, false),
            ("textureOnly", false, true, false, false),
            ("geometryAndTexture", true, true, false, false),
            ("live", false, false, true, false),
            ("liveAndTexture", false, true, true, false),
            ("clearcoatNormalWired", false, false, false, true),
        ]
        for v in variants {
            let d = doc(exportName: v.name, offset: v.offset, texture: v.texture, live: v.live,
                       clearcoatNormal: v.clearcoatNormal)
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
