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
