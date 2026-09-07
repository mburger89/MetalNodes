import Testing
@testable import MetalNodesCore

/// Builders shared by every material test in this suite.
enum MaterialFixture {
    /// A document whose root holds one Material Output, plus whatever `extra` adds.
    static func document(target: OutputTarget = .realityKit,
                         lighting: MaterialLightingModel = .lit,
                         _ extra: (inout Graph) -> Void = { _ in }) -> ShaderDocument {
        var doc = ShaderDocument()
        doc.settings.target = target
        doc.settings.lightingModel = lighting
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
        g.nodes[terminal.id] = terminal
        extra(&g)
        doc.root = g
        return doc
    }

    /// Adds a node of `defID` and wires its first output into the terminal's `socket`.
    @discardableResult
    static func wire(_ defID: String, into socket: String, _ g: inout Graph) -> NodeID {
        let node = NodeInstance(id: NodeID(), kind: .builtin(defID), position: .zero)
        g.nodes[node.id] = node
        let terminal = g.nodes.values.first { $0.kind == .builtin("output.material") }!
        let outName = NodeRegistry.builtin[defID]!.outputs.first!.name
        g.inputs[SocketRef(terminal.id, socket)] = SocketRef(node.id, outName)
        return node.id
    }
}

@Suite struct MaterialTerminalTests {
    @Test func theTerminalIdDependsOnTheTarget() {
        #expect(GraphValidator.terminalID(for: .fragment) == "output.fragment")
        #expect(GraphValidator.terminalID(for: .stitchable(.colorEffect)) == "output.fragment")
        #expect(GraphValidator.terminalID(for: .realityKit) == "output.material")
    }

    @Test func aRealityKitDocumentNeedsAMaterialOutput() {
        var doc = ShaderDocument()
        doc.settings.target = .realityKit
        doc.root = Graph()
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(diags.contains { $0.severity == .error && $0.message.contains("Material Output") })
        #expect(!diags.contains { $0.message.contains("Fragment Output") })
    }

    @Test func twoMaterialOutputsAreRefused() {
        let doc = MaterialFixture.document { g in
            let extra = NodeInstance(id: NodeID(), kind: .builtin("output.material"), position: .zero)
            g.nodes[extra.id] = extra
        }
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(diags.contains { $0.severity == .error && $0.message.contains("only one Material Output") })
    }

    /// Switching a document's target must not condemn the terminal the other target uses.
    @Test func theOtherTargetsTerminalIsIgnoredNotRefused() {
        let doc = MaterialFixture.document { g in
            let frag = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
            g.nodes[frag.id] = frag
        }
        let diags = GraphValidator.validate(document: doc, registry: .builtin, target: .realityKit)
        #expect(!diags.contains { $0.severity == .error })

        var fragmentDoc = doc
        fragmentDoc.settings.target = .fragment
        let back = GraphValidator.validate(document: fragmentDoc, registry: .builtin, target: .fragment)
        #expect(!back.contains { $0.severity == .error })
    }

    @Test func terminalLookupIsStableAcrossCalls() {
        let doc = MaterialFixture.document()
        let a = GraphValidator.terminal(in: doc.root, target: .realityKit)
        let b = GraphValidator.terminal(in: doc.root, target: .realityKit)
        #expect(a != nil)
        #expect(a == b)
        #expect(GraphValidator.terminal(in: doc.root, target: .fragment) == nil)
    }
}

@Suite struct MaterialRuleTests {
    private func errors(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
            .filter { $0.severity == .error }
    }
    private func warnings(_ doc: ShaderDocument) -> [Diagnostic] {
        GraphValidator.validate(document: doc, registry: .builtin, target: doc.settings.target)
            .filter { $0.severity == .warning }
    }

    // Rule 2 — stage legality.

    @Test func aSurfaceOnlyNodeInTheGeometryStageIsRefused() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.viewDirection", into: "positionOffset", &g)
        }
        #expect(errors(doc).contains { $0.message.contains("View Direction") && $0.message.contains("geometry") })
    }

    @Test func aGeometryOnlyNodeInTheSurfaceStageIsRefused() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.vertexID", into: "roughness", &g)
        }
        #expect(errors(doc).contains { $0.message.contains("Vertex ID") && $0.message.contains("surface") })
    }

    @Test func aStageAgnosticNodeIsFineInBoth() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.worldPosition", into: "positionOffset", &g)
            MaterialFixture.wire("input.modelPosition", into: "baseColor", &g)
        }
        #expect(errors(doc).isEmpty)
    }

    @Test func aSurfaceOnlyNodeInItsOwnStageIsFine() {
        let doc = MaterialFixture.document { g in
            MaterialFixture.wire("input.tangent", into: "normal", &g)
        }
        #expect(errors(doc).isEmpty)
    }

    // Rule 3 — target legality.

    /// Task 11 replaced the two hand-written strings with one the predicate produces, which covers
    /// both directions of the rule instead of one each. It still names the fix — the half a user
    /// acts on — but derives it rather than hardcoding it.
    @Test func mouseAndResolutionAreRefusedUnderRealityKit() {
        for (id, name) in [("input.mouse", "mouse"), ("input.resolution", "resolution")] {
            let doc = MaterialFixture.document { g in MaterialFixture.wire(id, into: "baseColor", &g) }
            #expect(errors(doc).contains {
                $0.message.contains("reads \(name), which the RealityKit Material target does not provide")
            }, "\(id)")
            #expect(errors(doc).contains { $0.message.contains("needs the Fragment (preview) or SwiftUI target") }, "\(id)")
            // Exactly one refusal, not one per stage as well: a node legal in no stage is a target
            // error, and rule 2 stands down for it.
            #expect(errors(doc).count == 1, "\(id)")
        }
    }

    @Test func aThreeDimensionalNodeIsRefusedUnderTheFragmentTarget() {
        var doc = ShaderDocument()
        doc.settings.target = .fragment
        var g = Graph()
        let terminal = NodeInstance(id: NodeID(), kind: .builtin("output.fragment"), position: .zero)
        let normal = NodeInstance(id: NodeID(), kind: .builtin("input.normal3d"), position: .zero)
        g.nodes[terminal.id] = terminal
        g.nodes[normal.id] = normal
        doc.root = g
        // The problem, in the vocabulary the predicate reasons in…
        #expect(errors(doc).contains {
            $0.message.contains("reads normal3d, which the Fragment (preview) target does not provide")
        })
        // …and the fix, which is the half the user acts on and the retired string carried.
        #expect(errors(doc).contains { $0.message.contains("needs the RealityKit Material target") })
    }

    @Test func aThreeDimensionalNodeIsFineUnderRealityKit() {
        let doc = MaterialFixture.document { g in MaterialFixture.wire("input.normal3d", into: "normal", &g) }
        #expect(errors(doc).isEmpty)
    }

    // Rule 4 — one texture slot.

    /// The limit is one texture **slot**, not one Texture Sample node (final review, Finding 6).
    /// `Emitter.requestTexture` allocates one slot per distinct asset in first-use order, so two
    /// nodes naming the same image both read `tex0` and export cleanly; two naming different images
    /// would need two slots, and `params.textures().custom()` is the only one there is.
    private func samplers(_ assets: [AssetID?]) -> ShaderDocument {
        MaterialFixture.document { g in
            let sockets = ["baseColor", "emissive", "normal"]
            for (i, a) in assets.enumerated() {
                let id = MaterialFixture.wire("texture.sample", into: sockets[i % sockets.count], &g)
                g.nodes[id]!.params["asset"] = .asset(a)
            }
        }
    }

    @Test func oneTextureSlotIsAllowedAndTwoAreNot() {
        let image = AssetID(), other = AssetID()
        #expect(errors(samplers([image])).isEmpty)
        // Two nodes, one asset: one slot, so this exports cleanly and must not be refused.
        #expect(errors(samplers([image, image])).isEmpty)
        // Two unassigned samples share the `nil` slot the same way.
        #expect(errors(samplers([nil, nil])).isEmpty)

        for pair in [[image, other], [nil, image], [image, nil]] {
            let doc = samplers(pair)
            let diags = errors(doc)
            #expect(diags.contains { $0.message.contains("one texture slot") }, "\(pair)")
            // Anchored on the sample that needs the second slot, not on the first — the first fits.
            let flagged = diags.first { $0.message.contains("one texture slot") }?.node
            let first = doc.root.nodes.values
                .filter { $0.kind == .builtin("texture.sample") }
                .min { $0.id.raw.uuidString < $1.id.raw.uuidString }
            #expect(flagged != nil, "\(pair)")
            #expect(flagged != first?.id, "\(pair)")
        }
        // Three nodes, two assets: what survives is one slot's worth, not one node's. Which asset
        // keeps the slot follows the deterministic id order the rule sorts by, so the count of
        // refused *nodes* is 1 or 2 — the invariant is that exactly one asset is left standing.
        let three = samplers([image, image, other])
        let flagged = Set(errors(three).filter { $0.message.contains("one texture slot") }.compactMap(\.node))
        #expect(!flagged.isEmpty)
        let survivors = three.root.nodes.values
            .filter { $0.kind == .builtin("texture.sample") && !flagged.contains($0.id) }
            .compactMap { inst -> AssetID? in
                if case .asset(let a)? = inst.params["asset"] { return a }
                return nil
            }
        #expect(Set(survivors).count == 1)
    }

    /// The consequence the rule used to get wrong: the emitter really does hand both nodes one
    /// slot, so the document it refused is a legal one-slot program that exports cleanly.
    @Test func twoSamplesOfOneAssetShareOneSlot() throws {
        let image = AssetID()
        let shader = try ShaderGenerator.generate(samplers([image, image]), target: .realityKit)
        #expect(shader.textures.count == 1)
        #expect(shader.textures.first?.asset == image)
    }

    @Test func aTextureSampleInsideAGroupIsRefused() throws {
        var doc = MaterialFixture.document()
        var def = GroupDefinition(id: GroupID(), name: "Sampler")
        var inner = Graph()
        for kind in [NodeKind.groupInput, .groupOutput, .builtin("texture.sample")] {
            let n = NodeInstance(id: NodeID(), kind: kind, position: .zero)
            inner.nodes[n.id] = n
        }
        def.graph = inner
        doc.definitions[def.id] = def
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        doc.root.nodes[instance.id] = instance
        #expect(errors(doc).contains { $0.message.contains("samples its texture in the root graph") })
    }

    // Rule 5 — lighting model warning.

    @Test func unlitWarnsWhenANonEmissiveSocketIsWired() {
        let doc = MaterialFixture.document(lighting: .unlit) { g in
            MaterialFixture.wire("input.color", into: "baseColor", &g)
        }
        #expect(warnings(doc).contains { $0.message.contains("only Emissive") })
        #expect(errors(doc).isEmpty)   // a warning, never an error
    }

    @Test func unlitIsSilentWhenOnlyEmissiveIsWired() {
        let doc = MaterialFixture.document(lighting: .unlit) { g in
            MaterialFixture.wire("input.color", into: "emissive", &g)
        }
        #expect(warnings(doc).isEmpty)
    }

    @Test func litNeverWarnsAboutSockets() {
        let doc = MaterialFixture.document(lighting: .lit) { g in
            MaterialFixture.wire("input.color", into: "baseColor", &g)
        }
        #expect(warnings(doc).isEmpty)
    }

    /// Rules must see inside group definitions the root actually instantiates — that is what
    /// `reachableDefinitions` is for, and a stage-illegal node hidden in a group is still illegal.
    @Test func aStageIllegalNodeInsideAReachableGroupIsRefused() throws {
        var doc = MaterialFixture.document()
        // `outputs` must be non-empty: stage reachability (unlike the definition-membership rules
        // above) is wire-based — it only walks into a definition once the instance itself is wired
        // from the terminal, so the fixture needs a real output socket to wire through.
        var def = GroupDefinition(id: GroupID(), name: "Inner", outputs: [SocketDecl(name: "out", type: .concrete(.float))])
        var inner = Graph()
        let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
        let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
        let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
        for n in [gin, gout, vid] { inner.nodes[n.id] = n }
        // Wired into the Group Output, not merely present on the canvas — the walk into a
        // definition is wire-reachable from its own output, same as `GroupCodegen` emits.
        inner.inputs[SocketRef(gout.id, "out")] = SocketRef(vid.id, "id")
        def.graph = inner
        doc.definitions[def.id] = def
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        doc.root.nodes[instance.id] = instance
        // Vertex ID is geometry-only; the instance is reachable from the surface stage's root.
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        if let out = def.outputs.first {
            doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(instance.id, out.name)
        }
        #expect(errors(doc).contains { $0.message.contains("Vertex ID") })
    }

    // Fix round 1 — false positives the review caught.

    /// Finding 1 (Critical): Position Offset is the geometry stage, not the surface stage — vertex
    /// displacement happens regardless of the lighting model, so an unlit material that only wires
    /// Position Offset is entirely correct and must not warn. Neither `unlitWarnsWhenA…` test above
    /// exercises a geometry socket; both only wire `baseColor`/`emissive` (surface sockets).
    @Test func unlitDoesNotWarnAboutPositionOffset() {
        let doc = MaterialFixture.document(lighting: .unlit) { g in
            MaterialFixture.wire("input.worldPosition", into: "positionOffset", &g)
        }
        #expect(warnings(doc).isEmpty)
    }

    /// Finding 2 (Important): a stage-illegal node left orphaned inside a group — on the canvas,
    /// but never wired to that definition's own Group Output — is in no program `GroupCodegen`
    /// emits, so it must not be flagged. The same node wired into the output still is.
    @Test func anOrphanedStageIllegalGroupNodeIsNotFlaggedButAWiredOneIs() throws {
        func makeDoc(wireVertexID: Bool) -> ShaderDocument {
            var doc = MaterialFixture.document()
            var def = GroupDefinition(id: GroupID(), name: "Inner", outputs: [SocketDecl(name: "out", type: .concrete(.float))])
            var inner = Graph()
            let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
            let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
            // Stage-agnostic, so it is always a legal source for the Group Output's wire.
            let agnostic = NodeInstance(id: NodeID(), kind: .builtin("input.float"), position: .zero)
            // Geometry-only — illegal from the surface stage the instance below is wired into.
            let vid = NodeInstance(id: NodeID(), kind: .builtin("input.vertexID"), position: .zero)
            for n in [gin, gout, agnostic, vid] { inner.nodes[n.id] = n }
            let source = wireVertexID ? SocketRef(vid.id, "id") : SocketRef(agnostic.id, "out")
            inner.inputs[SocketRef(gout.id, "out")] = source
            def.graph = inner
            doc.definitions[def.id] = def
            let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
            doc.root.nodes[instance.id] = instance
            let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
            doc.root.inputs[SocketRef(terminal.id, "roughness")] = SocketRef(instance.id, "out")
            return doc
        }

        #expect(errors(makeDoc(wireVertexID: false)).isEmpty)
        #expect(errors(makeDoc(wireVertexID: true)).contains { $0.message.contains("Vertex ID") })
    }

    // Final review — Finding 2 (Important): a 3D input inside a group definition.

    /// A group function is target-agnostic by design: `EmitEnvironment.groupFunction`'s `sys` has
    /// only `uv`/`time`/`resolution`/`mouse`, because one emitted function serves every target
    /// (spec §23.4). So a World Position inside a reachable definition emitted
    /// `v0 = /* ?sys.worldPosition */;` into **both** the preview program and `exportSource` — a
    /// raw MSL error the user cannot act on, and an exported `.metal` that will not compile.
    ///
    /// Rule 2 could not catch it (these nodes carry both stages) and rule 3 refused only Mouse and
    /// Resolution. Reachable by selecting a node and choosing Group Selection.
    private func wrapperDocument(wireIntoTheGroupOutput: Bool, nodeID: String = "input.worldPosition") -> ShaderDocument {
        var doc = MaterialFixture.document()
        var def = GroupDefinition(id: GroupID(), name: "Wrapper",
                                  outputs: [SocketDecl(name: "out", type: .concrete(.float3))])
        var inner = Graph()
        let gin = NodeInstance(id: NodeID(), kind: .groupInput, position: .zero)
        let gout = NodeInstance(id: NodeID(), kind: .groupOutput, position: .zero)
        let fallback = NodeInstance(id: NodeID(), kind: .builtin("input.float3"), position: .zero)
        let threeD = NodeInstance(id: NodeID(), kind: .builtin(nodeID), position: .zero)
        for n in [gin, gout, fallback, threeD] { inner.nodes[n.id] = n }
        let source = wireIntoTheGroupOutput
            ? SocketRef(threeD.id, NodeRegistry.builtin[nodeID]!.outputs.first!.name)
            : SocketRef(fallback.id, "out")
        inner.inputs[SocketRef(gout.id, "out")] = source
        def.graph = inner
        doc.definitions[def.id] = def
        let instance = NodeInstance(id: NodeID(), kind: .group(def.id), position: .zero)
        doc.root.nodes[instance.id] = instance
        let terminal = doc.root.nodes.values.first { $0.kind == .builtin("output.material") }!
        doc.root.inputs[SocketRef(terminal.id, "baseColor")] = SocketRef(instance.id, "out")
        return doc
    }

    @Test func aThreeDimensionalInputInsideAGroupIsRefused() {
        let diags = errors(wrapperDocument(wireIntoTheGroupOutput: true))
        #expect(diags.contains { $0.message.contains("World Position") && $0.message.contains("out of the group") })
        // Anchored on the offending node, so the canvas can point at it.
        #expect(diags.first { $0.message.contains("out of the group") }?.node != nil)
    }

    /// Every 3D input, not just the one the review reproduced. Vertex ID is geometry-only, so it
    /// also trips rule 2 from this surface-side instance — either refusal keeps it out of source.
    @Test func everyThreeDimensionalInputInsideAGroupIsRefused() {
        for def in BuiltinNodes.material3D where def.id != "output.material" {
            let doc = wrapperDocument(wireIntoTheGroupOutput: true, nodeID: def.id)
            #expect(!errors(doc).isEmpty, "\(def.id) was accepted inside a group definition")
        }
    }

    /// The mirror: the same node orphaned on the definition's canvas reaches no emitted function,
    /// so it must not be flagged — the principle fix round 1 settled for rule 2.
    @Test func anOrphanedThreeDimensionalGroupNodeIsNotFlagged() {
        #expect(errors(wrapperDocument(wireIntoTheGroupOutput: false)).isEmpty)
    }

    /// The consequence, end to end: neither product may carry an unresolved `{sys.…}` marker.
    /// Before the rule existed both `source` and `exportSource` contained
    /// `/* ?sys.worldPosition */`; now generation refuses the document outright.
    @Test func aGroupedThreeDimensionalInputNeverReachesGeneratedSource() {
        let doc = wrapperDocument(wireIntoTheGroupOutput: true)
        #expect(throws: GenerationError.self) {
            let shader = try ShaderGenerator.generate(doc, target: .realityKit)
            #expect(!shader.source.contains("?sys."))
            #expect(!(shader.exportSource ?? "").contains("?sys."))
        }
    }
}
