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

    @Test func mouseAndResolutionAreRefusedUnderRealityKit() {
        for id in ["input.mouse", "input.resolution"] {
            let doc = MaterialFixture.document { g in MaterialFixture.wire(id, into: "baseColor", &g) }
            #expect(errors(doc).contains { $0.message.contains("Fragment or SwiftUI target") }, "\(id)")
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
        #expect(errors(doc).contains { $0.message.contains("RealityKit Material target") })
    }

    @Test func aThreeDimensionalNodeIsFineUnderRealityKit() {
        let doc = MaterialFixture.document { g in MaterialFixture.wire("input.normal3d", into: "normal", &g) }
        #expect(errors(doc).isEmpty)
    }

    // Rule 4 — one texture slot.

    @Test func oneTextureSampleIsAllowedAndTwoAreNot() {
        let one = MaterialFixture.document { g in MaterialFixture.wire("texture.sample", into: "baseColor", &g) }
        #expect(errors(one).isEmpty)

        let two = MaterialFixture.document { g in
            MaterialFixture.wire("texture.sample", into: "baseColor", &g)
            MaterialFixture.wire("texture.sample", into: "emissive", &g)
        }
        let diags = errors(two)
        #expect(diags.contains { $0.message.contains("one texture slot") })
        // Anchored on the extra sample, not on the first — the first is the one to keep.
        #expect(diags.first { $0.message.contains("one texture slot") }?.node != nil)
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
}
