import Foundation

/// The four rules the RealityKit target adds beyond the terminal rules (spec §23.7). They live
/// apart from `GraphValidator` because they are the only rules that reason about stages, and
/// `Validation.swift` is long enough already.
public enum MaterialValidation {
    /// Rules 2–5. Rule 1 (the terminal) is `GraphValidator`'s, because every target has one.
    public static func diagnostics(document doc: ShaderDocument, registry: NodeRegistry,
                                   target: OutputTarget, reachable: [GroupDefinition]) -> [Diagnostic] {
        guard target == .realityKit else { return foreignNodeDiagnostics(doc, registry: registry, reachable: reachable) }
        guard let terminal = GraphValidator.terminal(in: doc.root, target: .realityKit) else { return [] }
        return stageDiagnostics(doc, registry: registry, terminal: terminal, reachable: reachable)
            + targetDiagnostics(doc, registry: registry, reachable: reachable)
            + definitionNodeDiagnostics(doc, registry: registry, reachable: reachable)
            + textureDiagnostics(doc, reachable: reachable)
            + lightingDiagnostics(doc, terminal: terminal)
    }

    /// Every node of the root and of a reachable definition, each with the graph it lives in.
    private static func allNodes(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [(NodeInstance, Graph)] {
        var out = doc.root.nodes.values
            .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
            .map { ($0, doc.root) }
        for d in reachable {
            out += d.graph.nodes.values
                .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                .map { ($0, d.graph) }
        }
        return out
    }

    private static func title(_ inst: NodeInstance, _ doc: ShaderDocument, _ registry: NodeRegistry) -> String {
        if case .builtin(let id) = inst.kind, let def = registry[id] { return inst.customTitle ?? def.title }
        return inst.customTitle ?? "Node"
    }

    // MARK: Rule 2 — stage legality

    /// A node whose `stages` omits the stage that reaches it. Reachability inside a definition is
    /// wire-based, the same as the root: once the walk reaches a `.group` instance, it continues
    /// from that definition's own Group Output (`TopoSort.order`, matching what `GroupCodegen`
    /// actually emits) rather than over every node the definition's canvas happens to hold — a
    /// node orphaned in a definition, never wired to its output, is in no emitted program and must
    /// not be flagged. A definition is still attributed to every stage that instantiates it,
    /// because one function body serves both callers.
    private static func stageDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry, terminal: NodeID,
                                         reachable: [GroupDefinition]) -> [Diagnostic] {
        var out: [Diagnostic] = []
        for stage in MaterialStage.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let order = MaterialCodegen.stageOrder(graph: doc.root, terminal: terminal, stage: stage)
            var toVisit: [(NodeInstance, Graph)] = order.compactMap { id in
                doc.root.nodes[id].map { ($0, doc.root) }
            }
            var visitedDefinitions = Set<GroupID>()
            var i = 0
            while i < toVisit.count {
                let (inst, _) = toVisit[i]; i += 1
                switch inst.kind {
                case .builtin(let id):
                    guard let def = registry[id], !def.stages.contains(stage) else { continue }
                    out.append(Diagnostic(.error,
                        "\(title(inst, doc, registry)) is not available in the \(stage.title) stage",
                        node: inst.id))
                case .group(let gid):
                    guard visitedDefinitions.insert(gid).inserted, let d = doc.definitions[gid],
                          let output = d.outputNode else { continue }
                    toVisit += TopoSort.order(d.graph, from: output).compactMap { id in
                        d.graph.nodes[id].map { ($0, d.graph) }
                    }
                case .groupInput, .groupOutput:
                    continue
                }
            }
        }
        return out
    }

    // MARK: Rule 3 — target legality

    /// Nodes that read a system value this target cannot supply.
    private static let twoDimensionalOnly: Set<String> = ["input.mouse", "input.resolution"]

    private static func targetDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                          reachable: [GroupDefinition]) -> [Diagnostic] {
        allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, twoDimensionalOnly.contains(id) else { return nil }
            return Diagnostic(.error, "\(title(inst, doc, registry)) needs the Fragment or SwiftUI target", node: inst.id)
        }
    }

    /// The nodes only the RealityKit target can emit — the 3D inputs, not the terminal, which is
    /// what makes the document a material in the first place.
    private static let threeDimensionalOnly: Set<String> =
        Set(BuiltinNodes.material3D.map(\.id)).subtracting(["output.material"])

    /// The mirror rule: a node that only RealityKit can emit, reachable under another target.
    /// Applies to every target *but* `.realityKit`, which is why it sits outside the guard above.
    private static func foreignNodeDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                               reachable: [GroupDefinition]) -> [Diagnostic] {
        allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, threeDimensionalOnly.contains(id) else { return nil }
            return Diagnostic(.error, "\(title(inst, doc, registry)) needs the RealityKit Material target", node: inst.id)
        }
    }

    /// The *inverse* of `foreignNodeDiagnostics`, and the same walk: under `.realityKit` a 3D input
    /// is legal in the root and illegal inside a group definition.
    ///
    /// A group function is target-agnostic by design — `EmitEnvironment.groupFunction`'s `sys`
    /// carries `uv`/`time`/`resolution`/`mouse` and nothing else, because one emitted function
    /// serves every target and every caller (spec §23.4). It therefore cannot spell
    /// `params.geometry().world_position()`, and without this rule a World Position inside a
    /// definition emitted `v0 = /* ?sys.worldPosition */;` into *both* the preview program (a raw
    /// MSL error the user cannot act on) and `exportSource` (a `.metal` file that will not
    /// compile). Rule 2 does not catch it — these nodes carry both stages — and rule 3 refuses only
    /// Mouse and Resolution, which have no counterpart in *any* material stage.
    ///
    /// Reachable definitions only, and inside each one only what is wire-reachable from its own
    /// Group Output — the breadth rule 2 uses and `GroupCodegen` actually emits. A 3D input left
    /// orphaned on a definition's canvas reaches no function, so it produces no marker and must not
    /// be flagged (fix round 1 settled that principle for rule 2).
    private static func definitionNodeDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                                  reachable: [GroupDefinition]) -> [Diagnostic] {
        reachable.flatMap { d -> [Diagnostic] in
            guard let output = d.outputNode else { return [] }
            return TopoSort.order(d.graph, from: output).compactMap { nodeID -> Diagnostic? in
                guard let inst = d.graph.nodes[nodeID], case .builtin(let id) = inst.kind,
                      threeDimensionalOnly.contains(id) else { return nil }
                return Diagnostic(.error,
                    "A RealityKit material reads \(title(inst, doc, registry)) in the root graph — move this node out of the group",
                    node: inst.id)
            }
        }
    }

    // MARK: Rule 4 — one texture slot

    private static func textureDiagnostics(_ doc: ShaderDocument, reachable: [GroupDefinition]) -> [Diagnostic] {
        var out: [Diagnostic] = []

        // A group function declares its texture parameters as `texture2d<float>` (spec §21.2), and
        // `params.textures().custom()` is a `texture2d<half>` — MSL converts neither. Rather than
        // fork the group-function signature per target for one slot, this target samples from the
        // root only. The same shape as M3's refusal, which M6 lifted for the Layer Effect.
        for d in reachable {
            for id in d.graph.nodes.values
                .filter({ $0.kind == .builtin("texture.sample") })
                .map(\.id)
                .sorted(by: { $0.raw.uuidString < $1.raw.uuidString }) {
                out.append(Diagnostic(.error,
                    "A RealityKit material samples its texture in the root graph — move this Texture Sample out of the group",
                    node: id))
            }
        }

        let samples = doc.root.nodes.values
            .filter { $0.kind == .builtin("texture.sample") }
            .map(\.id)
            .sorted { $0.raw.uuidString < $1.raw.uuidString }
        out += samples.dropFirst().map {
            Diagnostic(.error, "A RealityKit material has one texture slot — remove the extra Texture Sample", node: $0)
        }
        return out
    }

    // MARK: Rule 5 — lighting model

    private static func lightingDiagnostics(_ doc: ShaderDocument, terminal: NodeID) -> [Diagnostic] {
        guard doc.settings.lightingModel == .unlit else { return [] }
        // Only a *surface* socket other than Emissive matters here — a geometry socket like
        // Position Offset moves vertices regardless of the lighting model, so wiring it under
        // `.unlit` is correct and must not warn.
        let wired = BuiltinNodes.materialStages
            .filter { $0.value == .surface && $0.key != "emissive" }
            .keys
            .filter { doc.root.inputs[SocketRef(terminal, $0)] != nil }
        guard !wired.isEmpty else { return [] }
        return [Diagnostic(.warning, "Unlit materials render only Emissive", node: terminal)]
    }
}
