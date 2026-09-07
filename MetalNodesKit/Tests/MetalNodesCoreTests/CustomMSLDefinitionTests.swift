import Testing
import Foundation
@testable import MetalNodesCore

@Suite struct DefinitionBodyTests {
    @Test func aGraphBodyRoundTrips() throws {
        var d = GroupDefinition(name: "G")
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        var g = Graph(); g.nodes[n.id] = n
        d.body = .graph(g)
        let back = try JSONDecoder().decode(GroupDefinition.self, from: try JSONEncoder().encode(d))
        #expect(back == d)
        if case .graph(let bg) = back.body { #expect(bg.nodes.count == 1) } else { Issue.record("not a graph body") }
    }

    @Test func anMSLBodyRoundTrips() throws {
        var d = GroupDefinition(name: "Wobble")
        d.body = .msl("out = in_a * 2.0;")
        let back = try JSONDecoder().decode(GroupDefinition.self, from: try JSONEncoder().encode(d))
        #expect(back == d)
        if case .msl(let s) = back.body { #expect(s == "out = in_a * 2.0;") } else { Issue.record("not an msl body") }
    }

    /// Every document written before M8 carries a `graph` key and no `body`. Losing these is the
    /// worst defect this milestone could ship.
    ///
    /// (An `EntityID` encodes as a bare UUID string, not as `{"raw": …}` — `Identifiers.swift` —
    /// and a `Graph` writes `nodes`/`edges` as arrays — `Graph.swift`.)
    @Test func aLegacyDefinitionWithOnlyAGraphKeyStillDecodes() throws {
        let json = Data("""
        {"id":"E63408AB-F398-45E3-A306-E8B989C079CC","name":"Legacy","inputs":[],"outputs":[],
         "graph":{"nodes":[],"edges":[]},"accent":"purple"}
        """.utf8)
        let d = try JSONDecoder().decode(GroupDefinition.self, from: json)
        #expect(d.name == "Legacy")
        if case .graph = d.body {} else { Issue.record("legacy graph did not become a .graph body") }
    }

    /// A legacy definition's nodes and wires survive the migration, not just its `.graph` case.
    @Test func aLegacyDefinitionKeepsItsNodes() throws {
        var legacy = GroupDefinition.make(name: "Legacy")
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        legacy.graph.nodes[n.id] = n
        legacy.graph.connect(SocketRef(n.id, "out"), to: SocketRef(legacy.outputNode!, "out"))

        // Exactly what an M0–M7 build wrote: the same keys, with `graph` in place of `body`.
        var object: [String: Any] = [
            "id": legacy.id.raw.uuidString,
            "name": legacy.name,
            "inputs": [],
            "outputs": [],
            "accent": legacy.accent.rawValue,
        ]
        let graphJSON = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(legacy.graph))
        object["graph"] = graphJSON
        let data = try JSONSerialization.data(withJSONObject: object)

        let back = try JSONDecoder().decode(GroupDefinition.self, from: data)
        #expect(back == legacy)
        #expect(back.graph.nodes.count == 3)
        #expect(back.graph.inputs.count == 1)
    }

    /// A body kind a future build writes and this one has no case for **fails the decode**. The
    /// alternative — degrading to an empty graph — is unrecoverable: the next save would rewrite
    /// the user's source as an empty definition. Failing leaves the bytes on disk for a build that
    /// understands them. (The format-version gate should stop such a document first; this is the
    /// backstop, and it must be loud.)
    @Test func anUnknownBodyKindFailsTheDecodeRatherThanEmptyingTheDefinition() {
        let json = Data("""
        {"id":"E63408AB-F398-45E3-A306-E8B989C079CC","name":"Future","inputs":[],"outputs":[],
         "body":{"kind":"spirv","spirv":"…"},"accent":"purple"}
        """.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(GroupDefinition.self, from: json) }
    }

    /// A real M7 document, loaded end to end.
    @Test func anExistingSampleDocumentStillLoads() throws {
        let doc = ShaderDocument.sampleWithGroup()
        let back = try JSONDecoder().decode(ShaderDocument.self, from: try JSONEncoder().encode(doc))
        #expect(back.definitions.count == doc.definitions.count)
        #expect(GraphValidator.validate(document: back, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }.isEmpty)
    }

    @Test func theGraphConvenienceReadsEmptyForAnMSLBody() {
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        #expect(d.graph.nodes.isEmpty)
    }

    /// Writing a graph into a text definition is a category error, and the user's code is the
    /// thing that would be lost — so the write is dropped and the body keeps its kind.
    @Test func writingTheGraphConvenienceLeavesAnMSLBodyAlone() {
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        var g = Graph()
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        g.nodes[n.id] = n
        d.graph = g
        d.graph.nodes[NodeID()] = n                       // the in-place path, too
        guard case .msl(let text) = d.body else { Issue.record("body stopped being msl"); return }
        #expect(text == "out = 1.0;")
    }

    /// `document[.definition(id)] = g` is the editor's mutation channel for a graph. Against a
    /// `.msl` body it must leave the code alone rather than convert the definition.
    @Test func writingThroughTheDocumentSubscriptLeavesAnMSLBodyAlone() {
        var doc = ShaderDocument()
        var d = GroupDefinition(name: "W")
        d.body = .msl("out = 1.0;")
        doc.definitions[d.id] = d

        var g = Graph()
        let n = NodeInstance(kind: .builtin("input.float"), position: .zero)
        g.nodes[n.id] = n
        doc[.definition(d.id)] = g                        // the setter
        doc[.definition(d.id)].nodes[n.id] = n            // the `_modify` path

        guard case .msl(let text) = doc.definitions[d.id]?.body else { Issue.record("body stopped being msl"); return }
        #expect(text == "out = 1.0;")
        #expect(doc[.definition(d.id)].nodes.isEmpty)
    }
}

/// M8 is the first non-additive change to the document format: it writes a definition's `body`
/// and no longer writes `graph`, which no M0–M7 build can decode. The version number has to say so,
/// or those builds report "The shader could not be read" instead of naming the real cause.
@Suite struct DocumentFormatVersionTests {
    private func package(_ doc: ShaderDocument) throws -> FileWrapper {
        try ShaderPackage(document: doc, viewState: EditorViewState(), textures: [:]).fileWrapper()
    }

    private func documentJSON(_ wrapper: FileWrapper) throws -> [String: Any] {
        let data = try #require(wrapper.fileWrappers?["document.json"]?.regularFileContents)
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func aDocumentWrittenNowSaysVersionTwo() throws {
        #expect(ShaderDocument.currentFormatVersion == 2)
        let json = try documentJSON(try package(.sampleWithGroup()))
        #expect(json["formatVersion"] as? Int == 2)
    }

    /// A document migrated from M0–M7 carries `formatVersion: 1` in memory, but once it is saved
    /// its bytes are M8's, so what is written is the current version — not the one it was read as.
    @Test func aMigratedDocumentIsRewrittenAsVersionTwo() throws {
        var legacyJSON = try documentJSON(try package(.sampleWithGroup()))
        legacyJSON["formatVersion"] = 1
        let decoded = try JSONDecoder().decode(ShaderDocument.self,
                                               from: try JSONSerialization.data(withJSONObject: legacyJSON))
        #expect(decoded.formatVersion == 1)                     // read as what it said
        let json = try documentJSON(try package(decoded))
        #expect(json["formatVersion"] as? Int == 2)             // written as what it now is
    }

    /// The gate this bump exists to arm: a version this build does not know is named, not blamed
    /// on a decoding error (spec §21.1).
    @Test func aNewerDocumentIsRefusedByName() throws {
        let wrapper = try package(.sampleWithGroup())
        var json = try documentJSON(wrapper)
        json["formatVersion"] = 3
        wrapper.removeFileWrapper(try #require(wrapper.fileWrappers?["document.json"]))
        wrapper.addRegularFile(withContents: try JSONSerialization.data(withJSONObject: json),
                               preferredFilename: "document.json")
        #expect(throws: PackageError.newerFormat(3)) { try ShaderPackage(fileWrapper: wrapper) }
        #expect(PackageError.newerFormat(3).errorDescription == "This shader was saved by a newer version of MetalNodes")
    }
}

/// §24.9: every definition operation must behave over a `.msl` body, not only a `.graph` one.
@Suite struct MSLDefinitionOperationsTests {
    private func document() -> (ShaderDocument, GroupID, NodeID) {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Tint")
        def.inputs = [SocketDecl(name: "a", label: "A", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", label: "Out", type: .concrete(.float))]
        def.body = .msl("out = a * 2.0;")
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), position: .zero)
        doc.root.nodes[inst.id] = inst
        return (doc, def.id, inst.id)
    }

    @Test func renamingKeepsTheBody() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.rename(id, to: "Warm", in: doc))
        #expect(out.definitions[id]?.name == "Warm")
        let def = try #require(out.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    @Test func makeUniqueCopiesTheText() throws {
        let (doc, id, inst) = document()
        let out = try #require(GroupOperations.makeUnique(inst, in: .root, of: doc))
        #expect(out.definition != id)
        let copy = try #require(out.document.definitions[out.definition])
        guard case .msl(let b) = copy.body else { Issue.record("copy is not an msl body"); return }
        #expect(b == "out = a * 2.0;")
        // The original is untouched — that is what "unique" means.
        let original = try #require(out.document.definitions[id])
        guard case .msl(let orig) = original.body else { Issue.record("original changed shape"); return }
        #expect(orig == "out = a * 2.0;")
    }

    /// `deleteDefinition` refuses while the definition is still instantiated and removes it once
    /// it is not (spec §20.6) — the same for a text body as for a graph one. (The brief's version
    /// of this test expected the delete to cascade through the instance; it never has.)
    @Test func deletingIsRefusedWhileUsedAndRemovesTheDefinitionOnceItIsNot() throws {
        var (doc, id, inst) = document()
        #expect(GroupOperations.isUsed(id, in: doc))
        #expect(GroupOperations.deleteDefinition(id, in: doc) == nil)

        doc.root.remove(node: inst)
        let out = try #require(GroupOperations.deleteDefinition(id, in: doc))
        #expect(out.definitions[id] == nil)
    }

    /// Ungrouping splices a definition's subgraph into its parent. A `.msl` body has no subgraph
    /// to splice, so the operation has no meaning and must refuse rather than silently delete the
    /// instance and its code.
    @Test func ungroupingACodeDefinitionIsRefused() {
        let (doc, _, inst) = document()
        #expect(GroupOperations.ungroup(inst, in: .root, of: doc) == nil)
    }

    /// Renaming a socket renames the function's parameter. The user's text is never rewritten
    /// (Global Constraints), so the body now reads an identifier that no longer exists — and the
    /// compiler says so, on the user's own line (Task 9). That is the intended behaviour, not a
    /// gap: silently editing someone's code is worse than a legible error.
    @Test func renamingASocketLeavesTheBodyAlone() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.renameSocket(id, kind: .input, from: "a", to: "amount", in: doc))
        #expect(out.definitions[id]?.inputs.map(\.name) == ["amount"])
        let def = try #require(out.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    /// A rename still rewires every *instance* of the definition, whatever the body is made of.
    @Test func renamingASocketStillRewiresInstances() throws {
        var (doc, id, inst) = document()
        let src = NodeInstance(kind: .builtin("input.float"), position: .zero)
        doc.root.nodes[src.id] = src
        doc.root.connect(SocketRef(src.id, "out"), to: SocketRef(inst, "a"))
        let out = try #require(GroupOperations.renameSocket(id, kind: .input, from: "a", to: "amount", in: doc))
        #expect(out.root.inputs[SocketRef(inst, "amount")] == SocketRef(src.id, "out"))
        #expect(out.root.inputs[SocketRef(inst, "a")] == nil)
    }

    @Test func addingAndRemovingASocketLeavesTheBodyAlone() throws {
        let (doc, id, _) = document()
        let added = try #require(GroupOperations.addSocket(id, kind: .input, decl:
            SocketDecl(name: "b", type: .concrete(.float), default: .value(.float(0))), in: doc))
        #expect(added.definitions[id]?.inputs.map(\.name) == ["a", "b"])
        let removed = try #require(GroupOperations.removeSocket(id, kind: .input, name: "b", in: added))
        #expect(removed.definitions[id]?.inputs.map(\.name) == ["a"])
        let def = try #require(removed.definitions[id])
        guard case .msl(let b) = def.body else { Issue.record("body stopped being msl"); return }
        #expect(b == "out = a * 2.0;")
    }

    /// The other arm of the precondition a `.msl` body relaxes: a `.graph` definition that has
    /// lost a pseudo-node still refuses a socket edit, because the edit rewires through it.
    @Test func aGraphDefinitionMissingAPseudoNodeStillRefusesSocketEdits() throws {
        var doc = ShaderDocument()
        var def = GroupDefinition.make(name: "Broken")
        def.inputs = [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(0)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        let gout = try #require(def.outputNode)
        def.graph.nodes[gout] = nil
        doc.definitions[def.id] = def

        #expect(GroupOperations.renameSocket(def.id, kind: .input, from: "a", to: "amount", in: doc) == nil)
        #expect(GroupOperations.removeSocket(def.id, kind: .input, name: "a", in: doc) == nil)
    }

    @Test func setAccentKeepsTheBody() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.setAccent(id, .green, in: doc))
        #expect(out.definitions[id]?.accent == .green)
        let def = try #require(out.definitions[id])
        guard case .msl = def.body else { Issue.record("body stopped being msl"); return }
    }

    /// A `.msl` definition has no subgraph, so the pseudo-node rules ("has no Group Input") must
    /// not be applied to it — an empty graph is not what a text body is. What its *text* must
    /// satisfy is Task 7's question.
    @Test func aCodeDefinitionIsNotValidatedAsAnEmptyGraph() {
        var (doc, _, _) = document()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        doc.root.nodes[terminal.id] = terminal
        let errors = GraphValidator.validate(document: doc, registry: .builtin, target: .fragment)
            .filter { $0.severity == .error }
        #expect(errors.isEmpty, "\(errors.map(\.message))")
    }

    // MARK: Reserved names (fix round 1) — an output declared under a `.msl` definition is spliced
    // into the generated function body under its own bare name, in the same scope as the system
    // parameters (`uv`, `time`, `size`, `mouse`) and the `in_<name>`-prefixed inputs. A name that
    // collides there is a Metal redeclaration, not shadowing (verified against the toolchain), and
    // the user's own text is never rewritten — so the only fix is refusing the name where it is
    // chosen.

    @Test func addingAnOutputNamedForASystemParameterIsRefused() {
        let (doc, id, _) = document()
        for reserved in ["uv", "time", "size", "mouse"] {
            #expect(GroupOperations.addSocket(id, kind: .output,
                decl: SocketDecl(name: reserved, type: .concrete(.float)), in: doc) == nil, "\(reserved)")
        }
    }

    @Test func addingAnOutputThatCollidesWithAnExistingInputsPrefixedNameIsRefused() {
        let (doc, id, _) = document()   // has input "a" → parameter `in_a`
        #expect(GroupOperations.addSocket(id, kind: .output,
            decl: SocketDecl(name: "in_a", type: .concrete(.float)), in: doc) == nil)
    }

    /// The other direction of the same collision: an input named `x` becomes the parameter
    /// `in_x`, which is refused if an *output* is already bare-named `in_x` — the only branch of
    /// `mslNameCollides` the earlier round left untested.
    @Test func addingAnInputThatCollidesWithAnExistingOutputsPrefixedNameIsRefused() throws {
        let (doc, id, _) = document()   // has output "out"
        let withOutput = try #require(GroupOperations.addSocket(id, kind: .output,
            decl: SocketDecl(name: "in_x", type: .concrete(.float)), in: doc))
        #expect(GroupOperations.addSocket(id, kind: .input,
            decl: SocketDecl(name: "x", type: .concrete(.float), default: .value(.float(0))), in: withOutput) == nil)
    }

    /// Inputs are always spelled `in_<name>` in the body, so a bare `uv`/`time`/`size`/`mouse`
    /// input name never collides with the system parameters themselves.
    @Test func addingAnInputNamedForASystemParameterIsAllowed() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.addSocket(id, kind: .input,
            decl: SocketDecl(name: "uv", type: .concrete(.float2), default: .value(.float2(.zero))), in: doc))
        #expect(out.definitions[id]?.inputs.map(\.name).contains("uv") == true)
    }

    @Test func renamingAnOutputToASystemParameterNameIsRefused() {
        let (doc, id, _) = document()   // has output "out"
        #expect(GroupOperations.renameSocket(id, kind: .output, from: "out", to: "time", in: doc) == nil)
    }

    /// The same names are unrestricted on a `.graph` definition: its emitted statements never
    /// spell a socket's own name as a raw identifier (the emitter always synthesizes its own
    /// variable names), so there is nothing for a socket named `uv` or `time` to collide with.
    /// (Existing library content already relies on this — `NodeShapeTests` has a `.graph`
    /// definition input named `uv`, `GroupOperationsTests` one named `time`.)
    @Test func aGraphDefinitionIsUnrestrictedByTheMSLReservedNames() throws {
        var doc = ShaderDocument()
        let def = GroupDefinition.make(name: "G")
        doc.definitions[def.id] = def
        let out = try #require(GroupOperations.addSocket(def.id, kind: .output,
            decl: SocketDecl(name: "uv", type: .concrete(.float2)), in: doc))
        #expect(out.definitions[def.id]?.outputs.map(\.name).contains("uv") == true)
    }

    // MARK: Texture outputs — a `.texture`-typed output declares a `texture2d<float>` field in the
    // result struct, and neither body kind has a valid initializer for one nothing assigns (the
    // zero-init fallback is `0.0`, a `float`) — refused on both, at the only point either gains one.

    @Test func addingATextureOutputIsRefusedOnAnMSLDefinition() {
        let (doc, id, _) = document()
        #expect(GroupOperations.addSocket(id, kind: .output,
            decl: SocketDecl(name: "tex", type: .concrete(.texture)), in: doc) == nil)
    }

    @Test func addingATextureOutputIsRefusedOnAGraphDefinitionToo() {
        var doc = ShaderDocument()
        let def = GroupDefinition.make(name: "G")
        doc.definitions[def.id] = def
        #expect(GroupOperations.addSocket(def.id, kind: .output,
            decl: SocketDecl(name: "tex", type: .concrete(.texture)), in: doc) == nil)
    }

    /// A texture *input* has no zero-init problem — inputs are never zero-initialised, only
    /// declared as a parameter — so it is unaffected.
    @Test func addingATextureInputIsUnaffected() throws {
        let (doc, id, _) = document()
        let out = try #require(GroupOperations.addSocket(id, kind: .input,
            decl: SocketDecl(name: "tex", type: .concrete(.texture), default: .value(.float(0))), in: doc))
        #expect(out.definitions[id]?.inputs.map(\.name).contains("tex") == true)
    }
}

@Suite struct CustomMSLEmissionTests {
    /// A document with one `.msl` definition instantiated twice, both feeding the terminal.
    private func document(_ body: String = "out = in_a * 2.0;") -> ShaderDocument {
        var doc = ShaderDocument()
        var def = GroupDefinition(name: "Wobble")
        def.inputs = [SocketDecl(name: "a", type: .concrete(.float), default: .value(.float(1)))]
        def.outputs = [SocketDecl(name: "out", type: .concrete(.float))]
        def.body = .msl(body)
        doc.definitions[def.id] = def

        var g = Graph()
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        let one = NodeInstance(kind: .group(def.id), position: .zero)
        let two = NodeInstance(kind: .group(def.id), position: .zero)
        let mix = NodeInstance(kind: .builtin("math.mix"), position: .zero)
        for n in [terminal, one, two, mix] { g.nodes[n.id] = n }
        g.inputs[SocketRef(mix.id, "a")] = SocketRef(one.id, "out")
        g.inputs[SocketRef(mix.id, "b")] = SocketRef(two.id, "out")
        g.inputs[SocketRef(terminal.id, "color")] = SocketRef(mix.id, "out")
        doc.root = g
        return doc
    }

    @Test func theUserStatementsLandInTheFunctionBody() throws {
        let s = try ShaderGenerator.generate(document()).source
        #expect(s.contains("in_a * 2.0"))
        #expect(s.contains("mn_g_Wobble_"))
    }

    /// The property that distinguishes a definition from an Expression node: one function, two
    /// call sites (spec §24.3).
    @Test func twoInstancesShareOneFunction() throws {
        let s = try ShaderGenerator.generate(document()).source
        let decls = s.components(separatedBy: "mn_g_Wobble_").count - 1
        // One declaration plus two call sites = three occurrences of the function name.
        #expect(decls == 3)
    }

    @Test func aMultiLineBodyIsEmittedInOrder() throws {
        let s = try ShaderGenerator.generate(document("float d = in_a * 3.0;\nout = d + 1.0;")).source
        let d = try #require(s.range(of: "float d = in_a * 3.0;"))
        let o = try #require(s.range(of: "out = d + 1.0;"))
        #expect(d.lowerBound < o.lowerBound)
    }

    @Test func generationIsDeterministic() throws {
        let doc = document()
        let first = try ShaderGenerator.generate(doc).source
        let second = try ShaderGenerator.generate(doc).source
        #expect(first == second)
    }

    /// End-to-end against the real Metal compiler: substring checks alone missed the `out`
    /// redeclaration this task's fix round exists for (spec §24.3; caught only by actually
    /// compiling the generated scaffolding). `xcrun metal` is not always installed; skip silently
    /// when it is not (same pattern as `ExpressionNodeTests`).
    @Test func generatedMSLCompilesWithTheToolchainWhenAvailable() throws {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        probe.arguments = ["-sdk", "macosx", "metal", "--version"]
        probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
        guard probe.terminationStatus == 0 else { return }

        var def = GroupDefinition(name: "Kitchen Sink")
        def.outputs = [
            // (a) The bug this task's fix round exists for: an output literally named `out`
            //     collides with the epilogue's own former hardcoded local of that name.
            SocketDecl(name: "out", type: .concrete(.float)),
            // (b) Several further outputs of every type but `.texture` (refused outright at
            //     `GroupOperations.addSocket`, so not exercised here), none assigned by the body
            //     below — the zero-init fallback must be valid MSL for each of them.
            SocketDecl(name: "vecOut", type: .concrete(.float2)),
            SocketDecl(name: "colorOut", type: .concrete(.color)),
            SocketDecl(name: "countOut", type: .concrete(.int)),
            SocketDecl(name: "flagOut", type: .concrete(.bool)),
            // (c) A name that survives Critical-1's reserved-name refusal (it is not `uv`,
            //     `time`, `size`, `mouse`, nor `in_<input>`) but is exactly the *unguarded*
            //     result-struct local this definition's own struct name would otherwise produce
            //     — the precise case `uniqueResultVar`'s totality loop exists to survive.
            SocketDecl(name: "\(GroupCodegen.structName(def.id))_result", type: .concrete(.float3)),
        ]
        def.body = .msl("out = 1.0;")
        var doc = ShaderDocument()
        doc.definitions[def.id] = def
        let inst = NodeInstance(kind: .group(def.id), position: .zero)
        let terminal = NodeInstance(kind: .builtin("output.fragment"), position: .zero)
        doc.root.nodes[inst.id] = inst
        doc.root.nodes[terminal.id] = terminal
        doc.root.inputs[SocketRef(terminal.id, "color")] = SocketRef(inst.id, "out")
        doc.settings.exportName = "mslkitchensink"

        let files = try ShaderExport.files(for: doc, registry: .builtin)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mn-mslexport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(files[0].name)
        try files[0].contents.write(to: url, atomically: true, encoding: .utf8)
        let metal = Process()
        metal.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        metal.arguments = ["-sdk", "macosx", "metal", "-c", url.path, "-o", dir.appendingPathComponent("out.air").path]
        let err = Pipe(); metal.standardError = err; metal.standardOutput = FileHandle.nullDevice
        try metal.run(); metal.waitUntilExit()
        let log = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(metal.terminationStatus == 0, "\(log)")
    }
}
