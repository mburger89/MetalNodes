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
    /// coarse on purpose: a definition is attributed to every stage that instantiates it, because
    /// one function body serves both callers.
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
                    guard visitedDefinitions.insert(gid).inserted, let d = doc.definitions[gid] else { continue }
                    toVisit += d.graph.nodes.values
                        .sorted { $0.id.raw.uuidString < $1.id.raw.uuidString }
                        .map { ($0, d.graph) }
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

    /// The mirror rule: a node that only RealityKit can emit, reachable under another target.
    /// Applies to every target *but* `.realityKit`, which is why it sits outside the guard above.
    private static func foreignNodeDiagnostics(_ doc: ShaderDocument, registry: NodeRegistry,
                                               reachable: [GroupDefinition]) -> [Diagnostic] {
        let materialOnly = Set(BuiltinNodes.material3D.map(\.id)).subtracting(["output.material"])
        return allNodes(doc, reachable: reachable).compactMap { inst, _ in
            guard case .builtin(let id) = inst.kind, materialOnly.contains(id) else { return nil }
            return Diagnostic(.error, "\(title(inst, doc, registry)) needs the RealityKit Material target", node: inst.id)
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
        let wired = BuiltinNodes.materialStages.keys
            .filter { $0 != "emissive" && doc.root.inputs[SocketRef(terminal, $0)] != nil }
        guard !wired.isEmpty else { return [] }
        return [Diagnostic(.warning, "Unlit materials render only Emissive", node: terminal)]
    }
}
